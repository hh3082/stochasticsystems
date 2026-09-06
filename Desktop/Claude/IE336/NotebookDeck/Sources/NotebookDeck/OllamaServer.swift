import Foundation

/// Makes sure an Ollama server answers on the port the notebooks hard-code (11434).
/// If one is already there (the user's own Ollama.app), it is used as is; otherwise the
/// bundled `ollama serve` is started against the bundled, read-only model store.
final class OllamaServer {
    static let port = 11434
    static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    static let logURL = JupyterServer.logURL.deletingLastPathComponent().appendingPathComponent("ollama.log")

    private var process: Process?
    private var logHandle: FileHandle?
    var isRunning: Bool { process?.isRunning ?? false }

    static func isUp() async -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 2
        guard let (_, r) = try? await URLSession.shared.data(for: req),
              let h = r as? HTTPURLResponse else { return false }
        return h.statusCode == 200
    }

    static func models() async -> [String] {
        guard let (d, _) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("api/tags")),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = obj["models"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["name"] as? String }
    }

    /// Returns a one-line status for the toolbar.
    func ensureRunning() async -> String {
        if isRunning { return "Ollama: bundled" }
        if await Self.isUp() {
            let have = Set(await Self.models())
            let missing = BundledRuntime.bundledOllamaModels.filter { !have.contains($0) }
            AppLog.write("ollama: external server on \(Self.port), missing=\(missing)")
            return missing.isEmpty ? "Ollama: your own server" : "Ollama: your own server, missing \(missing.joined(separator: ", "))"
        }
        guard let exe = BundledRuntime.ollama, let models = BundledRuntime.ollamaModels else {
            return "Ollama: not running"
        }
        var env: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OLLAMA_HOST": "127.0.0.1:\(Self.port)",
            "OLLAMA_MODELS": models.path,
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }
        do {
            let log = try Watchdog.freshLog(Self.logURL, header: "$ OLLAMA_MODELS=\(models.path) \(exe.path) serve")
            let p = Watchdog.process(exe: exe, args: ["serve"], cwd: nil, env: env, log: log)
            try p.run()
            process = p
            logHandle = log
            AppLog.write("ollama: started bundled server pid \(p.processIdentifier)")
        } catch {
            AppLog.write("ollama: failed to start: \(error)")
            return "Ollama: failed to start"
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !(process?.isRunning ?? false) { return "Ollama: exited (see log)" }
            if await Self.isUp() { return "Ollama: bundled" }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return "Ollama: not responding"
    }

    func stop() {
        Watchdog.stop(process)
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }
}
