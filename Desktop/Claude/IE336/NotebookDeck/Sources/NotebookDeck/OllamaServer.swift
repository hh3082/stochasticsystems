import Foundation

struct OllamaModel: Identifiable, Hashable {
    let name: String
    let size: Int64
    let modified: String
    let parameterSize: String
    let quantization: String
    var id: String { name }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

enum OllamaError: LocalizedError {
    case server(String)
    case noCLI
    var errorDescription: String? {
        switch self {
        case .server(let s): return s
        case .noCLI: return "No `ollama` command-line tool found (the bundled one is missing and none is on PATH)."
        }
    }
}

/// Makes sure an Ollama server answers on the port the notebooks hard-code (11434).
/// If one is already there (the user's own Ollama.app), it is used as is; otherwise the
/// bundled `ollama serve` is started against a writable per-user model store. The app ships
/// no Ollama models: the Models window downloads the course models into that store.
/// The instance state (process, mode, the start in flight) is main-actor state; the static
/// requests to the server are nonisolated and run wherever they are awaited.
@MainActor
final class OllamaServer {
    nonisolated static let port = 11434
    nonisolated static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    nonisolated static let logURL = JupyterServer.logURL.deletingLastPathComponent().appendingPathComponent("ollama.log")

    /// Writable store the bundled server uses. Every model the bundled server has lives here,
    /// including those an earlier version of the app copied in from its bundle.
    nonisolated static let modelStore = BundledRuntime.supportDir.appendingPathComponent("ollama/models", isDirectory: true)

    private var process: Process?
    private var logHandle: FileHandle?
    var isRunning: Bool { process?.isRunning ?? false }

    /// Which server is answering, for the UI.
    enum Mode { case none, bundled, external }
    private(set) var mode: Mode = .none

    nonisolated static func isUp() async -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 2
        guard let (_, r) = try? await URLSession.shared.data(for: req),
              let h = r as? HTTPURLResponse else { return false }
        return h.statusCode == 200
    }

    /// The models the server lists (/api/tags), or nil when it does not answer with a list, so
    /// that "none installed" and "unknown" stay apart.
    nonisolated static func models() async -> [OllamaModel]? {
        guard let (d, r) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("api/tags")),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = obj["models"] as? [[String: Any]] else { return nil }
        return arr.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let details = m["details"] as? [String: Any] ?? [:]
            let modified = (m["modified_at"] as? String ?? "").prefix(10)
            return OllamaModel(name: name, size: (m["size"] as? NSNumber)?.int64Value ?? 0,
                               modified: String(modified),
                               parameterSize: details["parameter_size"] as? String ?? "",
                               quantization: details["quantization_level"] as? String ?? "")
        }
    }

    private var inFlight: Task<String, Never>?

    /// Starts the server if needed and returns the toolbar's status line, which also names
    /// the course models the server does not have.
    func status() async -> String {
        let base = await ensureRunning()
        guard mode != .none else { return base }
        return Self.statusLine(base, installed: await Self.models()?.map(\.name))
    }

    /// `base` followed by the course models missing from `installed` (the names /api/tags
    /// lists), with where to get them; `base` alone when none is missing or the list is unknown.
    nonisolated static func statusLine(_ base: String, installed: [String]?) -> String {
        guard let installed else { return base }
        let all = CourseModels.current
        let missing = all.filter { !$0.isInstalled(in: installed) }.map(\.name)
        if missing.isEmpty { return base }
        let what = missing.count == all.count ? "no course models installed"
                                               : "course models missing: " + missing.joined(separator: ", ")
        return "\(base), \(what) (Models > Manage Models…)"
    }

    /// Returns a one-line status for the toolbar. Concurrent callers share one start.
    func ensureRunning() async -> String {
        if isRunning { return "Ollama: bundled" }
        if let t = inFlight { return await t.value }
        let t = Task { await self.startIfNeeded() }
        inFlight = t
        let result = await t.value
        inFlight = nil
        return result
    }

    private func startIfNeeded() async -> String {
        if await Self.isUp() {
            if mode != .external { AppLog.write("ollama: external server on \(Self.port)") }
            mode = .external
            return "Ollama: your own server"
        }
        guard let exe = BundledRuntime.ollama else {
            mode = .none
            return "Ollama: not running"
        }
        let store = Self.modelStore
        do {
            try await Task.detached { try BundledRuntime.prepareOllamaStore(store) }.value
        } catch {
            AppLog.write("ollama: preparing the store failed: \(error)")
            return "Ollama: could not prepare model store"
        }
        var env: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OLLAMA_HOST": "127.0.0.1:\(Self.port)",
            "OLLAMA_MODELS": store.path,
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }
        do {
            let log = try Watchdog.freshLog(Self.logURL, header: "$ OLLAMA_MODELS=\(store.path) \(exe.path) serve")
            let p = Watchdog.process(exe: exe, args: ["serve"], cwd: nil, env: env, log: log)
            try p.run()
            process = p
            logHandle = log
            mode = .bundled
            AppLog.write("ollama: started bundled server pid \(p.processIdentifier)")
        } catch {
            AppLog.write("ollama: failed to start: \(error)")
            mode = .none
            return "Ollama: failed to start"
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !(process?.isRunning ?? false) { mode = .none; return "Ollama: exited (see log)" }
            if await Self.isUp() { return "Ollama: bundled" }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return "Ollama: not responding"
    }

    func stop() {
        Watchdog.stop(process)
        process = nil
        mode = .none
        try? logHandle?.close()
        logHandle = nil
    }

    // MARK: - Model management (works against whichever server answers on the port)

    /// Pulls a model from the Ollama registry (or hf.co/OWNER/REPO[:TAG] from Hugging Face),
    /// reporting `(status, fraction)` as it streams. Cancelling the calling task closes the
    /// stream, which stops the download; Ollama keeps the finished parts for the next try.
    nonisolated static func pull(_ name: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "name": name, "stream": true])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.server("Ollama refused the pull request (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw OllamaError.server(err) }
            let status = obj["status"] as? String ?? ""
            var fraction: Double? = nil
            if let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0,
               let done = (obj["completed"] as? NSNumber)?.doubleValue {
                fraction = done / total
            }
            progress(status, fraction)
        }
    }

    /// True for the statuses a pull reports once every file has arrived ("verifying sha256
    /// digest", "writing manifest", "success" under Ollama 0.33.3). From then on the server
    /// finishes the pull and registers the model even when the client disconnects.
    nonisolated static func pullIsPastDownload(_ status: String) -> Bool {
        status.hasPrefix("verifying") || status == "writing manifest" || status == "success"
    }

    nonisolated static func delete(_ name: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "name": name])
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw OllamaError.server(msg ?? "Could not delete \(name).")
        }
    }

    nonisolated static let modelNameRule = "A model name uses letters, digits, '_', '-' and '.', starts with a letter or digit, and may end in a :tag, e.g. mymodel:7b."

    /// True for a name Ollama can store: [host/][namespace/]model[:tag], each part starting with
    /// a letter, digit or '_' and going on with letters, digits, '_', '-' and '.'.
    nonisolated static func isValidModelName(_ name: String) -> Bool {
        var base = Substring(name)
        if let colon = name.lastIndex(of: ":") {
            guard isValidNamePart(name[name.index(after: colon)...]) else { return false }
            base = name[..<colon]
        }
        let parts = base.split(separator: "/", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy(isValidNamePart)
    }

    private nonisolated static func isValidNamePart(_ s: Substring) -> Bool {
        guard let first = s.first, s.count <= 350, first.isASCII, first.isLetter || first.isNumber || first == "_" else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
    }

    /// The model's details from /api/show: template, system, parameters, ...
    nonisolated static func show(_ name: String) async throws -> [String: Any] {
        try await post("api/show", ["model": name])
    }

    /// Gives an existing model a second name; both names share the same files.
    nonisolated static func copy(_ source: String, to destination: String) async throws {
        _ = try await post("api/copy", ["source": source, "destination": destination])
    }

    /// Recreates `model` from the model `from` with a new template and, if given, system message
    /// (the JSON form of /api/create).
    nonisolated static func create(model: String, from: String, template: String, system: String?) async throws {
        var body: [String: Any] = ["model": model, "from": from, "template": template, "stream": false]
        if let system { body["system"] = system }
        _ = try await post("api/create", body, timeout: 600)
    }

    private nonisolated static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let err = obj["error"] as? String { throw OllamaError.server(err) }
        guard code == 200 else { throw OllamaError.server("Ollama refused /\(path) (HTTP \(code)).") }
        return obj
    }

    /// Registers a GGUF file on disk as a model, via `ollama create`, on the running server.
    nonisolated static func importGGUF(file: URL, as name: String) async throws -> String {
        let cli: URL
        if let b = BundledRuntime.ollama { cli = b }
        else if let p = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { cli = URL(fileURLWithPath: p) }
        else { throw OllamaError.noCLI }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notebookdeck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modelfile = dir.appendingPathComponent("Modelfile")
        try "FROM \(file.path)\n".write(to: modelfile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        return try await Task.detached { () -> String in
            let p = Process()
            p.executableURL = cli
            // "--" ends the options, so a name such as "-h" is taken as a name, not a flag.
            p.arguments = ["create", "-f", modelfile.path, "--", name]
            p.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "PATH": "/usr/bin:/bin", "OLLAMA_HOST": "127.0.0.1:\(port)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw OllamaError.server("ollama create failed:\n" + out.split(separator: "\n").suffix(6).joined(separator: "\n"))
            }
            return out
        }.value
    }
}
