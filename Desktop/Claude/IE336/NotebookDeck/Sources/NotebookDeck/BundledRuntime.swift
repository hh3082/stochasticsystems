import Foundation

/// Locates the self-contained runtime shipped inside the app bundle
/// (Contents/Resources/runtime) and the notebooks shipped with it
/// (Contents/Resources/notebooks). Everything is optional: a bare build without
/// the runtime falls back to whatever `jupyter` and Ollama the machine has.
enum BundledRuntime {
    private static let fm = FileManager.default

    static let root: URL? = existing(Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true))
    static let python: URL? = existing(root?.appendingPathComponent("python/bin/python3"))
    static let ollama: URL? = existing(root?.appendingPathComponent("ollama/ollama"))
    static let hfHome: URL? = existing(root?.appendingPathComponent("models/hf", isDirectory: true))
    static let bundledNotebooks: URL? = existing(Bundle.main.resourceURL?.appendingPathComponent("notebooks", isDirectory: true))

    static var isAvailable: Bool { python != nil }

    /// Per-user writable state (Jupyter config/data, matplotlib cache, ...).
    static let supportDir: URL = {
        let d = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotebookDeck", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Where the shipped notebooks are copied so students can edit and save them. Kept out of
    /// ~/Documents so macOS never has to ask for folder access.
    static let userNotebooksDir: URL = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("NotebookDeck Notebooks", isDirectory: true)
    private static let legacyNotebooksDir: URL = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/NotebookDeck Notebooks", isDirectory: true)

    /// Moves a folder created by earlier versions in ~/Documents to the new location, once.
    static func migrateNotebooksFolder() {
        guard !fm.fileExists(atPath: userNotebooksDir.path), fm.fileExists(atPath: legacyNotebooksDir.path) else { return }
        do {
            try fm.moveItem(at: legacyNotebooksDir, to: userNotebooksDir)
            AppLog.write("notebooks: moved \(legacyNotebooksDir.path) -> \(userNotebooksDir.path)")
        } catch {
            AppLog.write("notebooks: could not move legacy folder: \(error)")
        }
    }

    /// A saved path under the old Documents folder, rewritten to the new one.
    static func remapLegacyPath(_ path: String) -> String {
        let old = legacyNotebooksDir.path
        return path.hasPrefix(old + "/") ? userNotebooksDir.path + path.dropFirst(old.count) : path
    }

    static var bundledNotebookNames: [String] {
        guard let d = bundledNotebooks, let items = try? fm.contentsOfDirectory(atPath: d.path) else { return [] }
        return items.filter { $0.hasSuffix(".ipynb") }.sorted()
    }

    /// Copies the shipped notebooks into `userNotebooksDir`. Existing files are kept
    /// unless `overwrite` is set. Returns the directory.
    @discardableResult
    static func installNotebooks(overwrite: Bool) throws -> URL {
        migrateNotebooksFolder()
        guard let src = bundledNotebooks else { return userNotebooksDir }
        try fm.createDirectory(at: userNotebooksDir, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) where !name.hasPrefix(".") {
            let from = src.appendingPathComponent(name)
            let to = userNotebooksDir.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) {
                if !overwrite { continue }
                try fm.removeItem(at: to)
            }
            try fm.copyItem(at: from, to: to)
        }
        return userNotebooksDir
    }

    /// Creates the writable Ollama store if needed. The app ships no Ollama models (build.sh
    /// leaves Runtime/models/ollama out; the Models window downloads the course models), so
    /// nothing is copied in, and an existing store, including one an earlier version seeded
    /// with qwen2.5:0.5b and qwen2.5:3b, is used as it is.
    static func prepareOllamaStore(_ store: URL) throws {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        AppLog.write("ollama: no models are bundled; using the store at \(store.path) as it is")
    }

    /// Environment for the bundled Jupyter server (and, by inheritance, its kernels):
    /// nothing from the user's own Python, Jupyter, or Hugging Face setup leaks in.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "VIRTUAL_ENV",
                  "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "JUPYTER_PATH", "JUPYTER_TOKEN",
                  "HF_HUB_CACHE", "TRANSFORMERS_CACHE", "OLLAMA_MODELS"] {
            env.removeValue(forKey: k)
        }
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let py = python { path.insert(py.deletingLastPathComponent().path, at: 0) }
        if let ol = ollama { path.insert(ol.deletingLastPathComponent().path, at: 1) }
        env["PATH"] = path.joined(separator: ":")
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        // The bundle is signed and must never change. stage_runtime.sh compiles every module in
        // advance; this keeps Python from writing a .pyc into the app if one is ever missing.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        let sub = { (name: String) -> String in
            let d = supportDir.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d.path
        }
        env["JUPYTER_DATA_DIR"] = sub("jupyter/data")
        env["JUPYTER_CONFIG_DIR"] = sub("jupyter/config")
        env["JUPYTER_RUNTIME_DIR"] = sub("jupyter/runtime")
        env["IPYTHONDIR"] = sub("ipython")
        env["MPLCONFIGDIR"] = sub("matplotlib")
        if let hf = hfHome {
            env["HF_HOME"] = hf.path
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
            // hf_xet writes its logs under $HF_XET_CACHE, which defaults to $HF_HOME/xet (inside the bundle).
            env["HF_XET_CACHE"] = sub("hf-xet")
        }
        env["OLLAMA_HOST"] = "127.0.0.1:\(OllamaServer.port)"
        return env
    }

    private static func existing(_ u: URL?) -> URL? {
        guard let u, fm.fileExists(atPath: u.path) else { return nil }
        return u
    }
}

/// Spawns a child under a tiny watchdog shell so it dies whenever this app does
/// (crash, force quit, SIGKILL), instead of being orphaned.
enum Watchdog {
    static func process(exe: URL, args: [String], cwd: URL?, env: [String: String], log: FileHandle) -> Process {
        let script = """
        "$0" "$@" & child=$!
        trap 'kill $child 2>/dev/null; exit 0' EXIT TERM INT HUP
        while kill -0 $PPID 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, exe.path] + args
        p.currentDirectoryURL = cwd
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        return p
    }

    static func stop(_ p: Process?) {
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    static func freshLog(_ url: URL, header: String) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let h = try FileHandle(forWritingTo: url)
        h.write((header + "\n\n").data(using: .utf8)!)
        return h
    }
}
