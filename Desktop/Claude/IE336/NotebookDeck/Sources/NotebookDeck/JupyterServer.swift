import Foundation
import Darwin

enum JupyterError: LocalizedError {
    case notFound
    case exited(String)
    case timeout(String)
    case noPort

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Could not find a `jupyter` executable. Use File > Set Jupyter Executable… to point at one (for example ~/miniconda3/bin/jupyter)."
        case .exited(let log):
            return "The Jupyter server exited before it was ready.\n\n\(log)"
        case .timeout(let log):
            return "The Jupyter server did not become ready within 60 seconds.\n\n\(log)"
        case .noPort:
            return "Could not allocate a free TCP port."
        }
    }
}

enum AppLog {
    static let url: URL = JupyterServer.logURL.deletingLastPathComponent().appendingPathComponent("app.log")
    static func write(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Owns one `jupyter lab` (or `jupyter notebook`) process rooted at a directory.
final class JupyterServer {
    private(set) var process: Process?
    private(set) var rootDir: URL?
    private(set) var port: Int = 0
    private(set) var token: String = ""
    private(set) var frontend: Frontend = .lab
    private var logHandle: FileHandle?

    enum Frontend { case lab, notebook7, notebook6 }

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotebookDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jupyter.log")
    }()

    var isRunning: Bool { process?.isRunning ?? false }

    var baseURL: URL? {
        port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)/")
    }

    /// URL that opens `file` (which must live under `rootDir`) in the running frontend.
    func url(for file: URL) -> URL? {
        guard let base = baseURL, let root = rootDir else { return nil }
        let rel = file.path.hasPrefix(root.path + "/")
            ? String(file.path.dropFirst(root.path.count + 1))
            : file.lastPathComponent
        let prefix: String
        switch frontend {
        case .lab: prefix = "lab/tree/"
        case .notebook7, .notebook6: prefix = "notebooks/"
        }
        var comps = URLComponents(url: base.appendingPathComponent(prefix + rel), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    /// The JupyterLab workspace (file browser) at the server root.
    var labURL: URL? {
        guard let base = baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent(frontend == .lab ? "lab" : "tree"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    func serves(_ file: URL) -> Bool {
        guard isRunning, let root = rootDir else { return false }
        return file.path.hasPrefix(root.path + "/")
    }

    // MARK: - Locating jupyter

    static func findJupyter() -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "jupyterPath"), fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        // Ask the login shell first: this picks up conda init, pyenv, etc.
        if let fromShell = shellLookup(), fm.isExecutableFile(atPath: fromShell) {
            return URL(fileURLWithPath: fromShell)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += [
            "\(home)/miniconda3/bin", "\(home)/anaconda3/bin", "\(home)/miniforge3/bin",
            "\(home)/mambaforge/bin", "/opt/miniconda3/bin", "/opt/anaconda3/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "/Library/Frameworks/Python.framework/Versions/Current/bin",
        ]
        for d in dirs where fm.isExecutableFile(atPath: d + "/jupyter") {
            return URL(fileURLWithPath: d + "/jupyter")
        }
        return nil
    }

    private static func shellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "command -v jupyter"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Do not hang forever on a misbehaving rc file.
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let line = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (line?.hasPrefix("/") ?? false) ? line : nil
    }

    private static func run(_ exe: URL, _ args: [String], env: [String: String]? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env ?? childEnvironment(for: exe)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    private static func childEnvironment(for exe: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = exe.deletingLastPathComponent().path
        env["PATH"] = binDir + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["PYTHONUNBUFFERED"] = "1"
        env.removeValue(forKey: "JUPYTER_TOKEN")
        return env
    }

    private static func detectFrontend(_ exe: URL) -> Frontend {
        let (labStatus, _) = run(exe, ["lab", "--version"])
        if labStatus == 0 { return .lab }
        let (nbStatus, out) = run(exe, ["notebook", "--version"])
        if nbStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("6") { return .notebook6 }
        return .notebook7
    }

    // MARK: - Lifecycle

    static func freePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw JupyterError.noPort }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw JupyterError.noPort }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        guard got == 0 else { throw JupyterError.noPort }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    struct Launcher {
        let exe: URL
        let prefix: [String]
        let frontend: Frontend
        let env: [String: String]
        let label: String
    }

    /// The bundled runtime wins; otherwise whatever `jupyter` the machine has.
    static func resolveLauncher() -> Launcher? {
        if let py = BundledRuntime.python {
            return Launcher(exe: py, prefix: ["-m", "jupyterlab"], frontend: .lab,
                            env: BundledRuntime.environment(), label: "bundled")
        }
        guard let exe = findJupyter() else { return nil }
        let fe = detectFrontend(exe)
        return Launcher(exe: exe, prefix: [fe == .lab ? "lab" : "notebook"], frontend: fe,
                        env: childEnvironment(for: exe), label: "system")
    }

    private(set) var label = ""

    /// Starts a server rooted at `rootDir`, replacing any running one. Returns the base URL.
    func start(rootDir: URL) async throws -> URL {
        stop()
        AppLog.write("start: rootDir=\(rootDir.path)")
        guard let launcher = await Task.detached(operation: { Self.resolveLauncher() }).value else {
            AppLog.write("start: jupyter not found"); throw JupyterError.notFound
        }
        let frontend = launcher.frontend
        AppLog.write("start: exe=\(launcher.exe.path) \(launcher.prefix) frontend=\(frontend) [\(launcher.label)]")
        let port = try Self.freePort()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let appPrefix = (frontend == .notebook6) ? "NotebookApp" : "ServerApp"
        var args: [String] = launcher.prefix + ["--no-browser", "--ip=127.0.0.1", "--port=\(port)"]
        args += [
            "--\(appPrefix).token=\(token)",
            "--\(appPrefix).password=",
            "--\(appPrefix).open_browser=False",
            "--\(appPrefix).port_retries=0",
        ]
        if frontend == .notebook6 {
            args.append("--\(appPrefix).notebook_dir=\(rootDir.path)")
        } else {
            args.append("--\(appPrefix).root_dir=\(rootDir.path)")
        }

        let log = try Watchdog.freshLog(Self.logURL, header: "$ \(launcher.exe.path) \(args.joined(separator: " "))")
        let p = Watchdog.process(exe: launcher.exe, args: args, cwd: rootDir, env: launcher.env, log: log)
        try p.run()

        self.process = p
        self.rootDir = rootDir
        self.port = port
        self.token = token
        self.frontend = frontend
        self.label = launcher.label
        self.logHandle = log

        let base = baseURL!
        let statusURL = base.appendingPathComponent("api/status")
        var comps = URLComponents(url: statusURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        let probe = comps.url!

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !p.isRunning { throw JupyterError.exited(Self.logTail()) }
            if let (_, resp) = try? await URLSession.shared.data(from: probe),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                AppLog.write("start: ready at \(base)")
                return base
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        stop()
        throw JupyterError.timeout(Self.logTail())
    }

    func stop() {
        guard let p = process else { return }
        Watchdog.stop(p)
        process = nil
        rootDir = nil
        port = 0
        token = ""
        try? logHandle?.close()
        logHandle = nil
    }

    /// Packages every lab needs (the book's requirements.txt plus requirements-finetune.txt),
    /// and ipywidgets with its JupyterLab extension for the prompt box in the ch03 lab.
    static let requiredModules = ["numpy", "scipy", "matplotlib", "requests", "jupyterlab", "ipykernel", "torch", "transformers",
                                  "ipywidgets", "jupyterlab_widgets"]

    struct DependencyReport {
        var versions: [String: String] = [:]
        var missing: [String] = []
        var ok: Bool { missing.isEmpty }
        var summary: String {
            ok ? "Python deps OK" : "Python deps missing: \(missing.joined(separator: ", "))"
        }
    }

    /// Imports every required package in the launcher's Python. Doubles as a warm-up: the
    /// first `import torch` in a kernel is seconds faster once the files are in the disk cache.
    static func checkDependencies() -> DependencyReport {
        var report = DependencyReport()
        guard let launcher = resolveLauncher() else { report.missing = requiredModules; return report }
        let python: URL
        var args: [String]
        if launcher.label == "bundled" {
            python = launcher.exe
        } else {
            // System jupyter: ask the shebang's interpreter, falling back to python3 on PATH.
            let first = (try? String(contentsOf: launcher.exe, encoding: .utf8))?.split(separator: "\n").first ?? ""
            let she = first.hasPrefix("#!") ? String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces) : "/usr/bin/env python3"
            python = URL(fileURLWithPath: she.split(separator: " ").first.map(String.init) ?? "/usr/bin/env")
        }
        let script = """
        import importlib, json, sys
        out = {}
        for m in sys.argv[1:]:
            try:
                mod = importlib.import_module(m)
                out[m] = getattr(mod, "__version__", "ok")
            except Exception as e:
                out[m] = "MISSING: " + type(e).__name__
        print(json.dumps(out))
        """
        args = ["-c", script] + requiredModules
        let (status, out) = run(python, args, env: launcher.env)
        AppLog.write("deps: \(python.path) exit=\(status) \(out.split(separator: "\n").last ?? "")")
        guard status == 0, let line = out.split(separator: "\n").last, let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            report.missing = ["(could not run Python: \(out.suffix(200)))"]
            return report
        }
        for m in requiredModules {
            let v = dict[m] ?? "MISSING"
            if v.hasPrefix("MISSING") { report.missing.append(m) } else { report.versions[m] = v }
        }
        return report
    }

    /// Runs Resources/runtime_check.py under the bundled Python: every installed package must
    /// import, and nothing may come from outside the bundle. Returns the report text.
    static func fullAudit() -> String {
        guard let launcher = resolveLauncher(), launcher.label == "bundled",
              let script = Bundle.main.url(forResource: "runtime_check", withExtension: "py") else {
            return "The full audit needs the bundled runtime."
        }
        // -I ignores PYTHONDONTWRITEBYTECODE along with the other PYTHON* variables, so -B says it again.
        let (status, out) = run(launcher.exe, ["-I", "-B", script.path], env: launcher.env)
        guard status == 0, let line = out.split(separator: "\n").last, let data = line.data(using: .utf8),
              let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Audit failed to run:\n\(out.suffix(400))"
        }
        var lines = ["Python \(r["python"] ?? "?") at \(r["prefix"] ?? "?")",
                     "\(r["distributions"] ?? 0) packages installed, \(r["imported"] ?? 0) modules imported"]
        let failures = r["failures"] as? [[String: String]] ?? []
        let outsidePath = r["outside_path"] as? [String] ?? []
        let outsideMods = r["outside_modules"] as? [String] ?? []
        if failures.isEmpty && outsidePath.isEmpty && outsideMods.isEmpty {
            lines.append(""); lines.append("Everything imports, and nothing is loaded from outside the app.")
        } else {
            for f in failures { lines.append("FAILED \(f["distribution"] ?? "") / \(f["module"] ?? ""): \(f["error"] ?? "")") }
            if !outsidePath.isEmpty { lines.append("sys.path outside the app: \(outsidePath.joined(separator: ", "))") }
            if !outsideMods.isEmpty { lines.append("modules from outside the app: \(outsideMods.prefix(5).joined(separator: ", "))") }
        }
        if let m = try? String(contentsOf: launcher.exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MANIFEST.txt"), encoding: .utf8) {
            lines.append(""); lines.append(m.split(separator: "\n").prefix(12).joined(separator: "\n"))
        }
        AppLog.write("audit: \(line)")
        return lines.joined(separator: "\n")
    }

    static func logTail(lines: Int = 15) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
