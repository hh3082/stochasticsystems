import Foundation

/// Downloads a GGUF file from a pasted link into the app's downloads folder.
enum LinkDownload {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloaded files wait here until they are imported; each is deleted once Ollama has its copy.
    static let downloadsDir = BundledRuntime.supportDir.appendingPathComponent("downloads", isDirectory: true)

    /// Copies of the file that must fit on the disk: the download, and the two that Ollama 0.33.3
    /// writes while importing it (the uploaded file and a rewritten one).
    static let copiesNeeded: Int64 = 3
    /// Space left over after all copies, and the floor below which a running download stops.
    static let reserve: Int64 = 1_000_000_000

    /// Turns a pasted link into a direct download URL: https only; Dropbox share pages get
    /// dl=1, Hugging Face /blob/ pages become /resolve/. Google Drive is refused, since its
    /// large files sit behind a confirmation page that needs a browser.
    static func directURL(for input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Failure(message: "Paste a link to a .gguf file.") }
        if let scheme = scheme(of: s) {
            guard scheme == "https" else {
                throw Failure(message: "Only https links can be downloaded (this one is \(scheme)).")
            }
        } else {
            s = "https://" + s
        }
        guard var c = URLComponents(string: s), var host = c.host?.lowercased(), !host.isEmpty else {
            throw Failure(message: "Not a valid link: \(input)")
        }
        guard c.user == nil, c.password == nil else {
            throw Failure(message: "Links that carry a user name or password cannot be downloaded here.")
        }
        if host.hasSuffix(".") { host.removeLast() }     // "dropbox.com." names the same host
        if ["drive.google.com", "docs.google.com", "drive.usercontent.google.com"].contains(host) {
            throw Failure(message: "Google Drive links cannot be downloaded here. Open the link in a browser, download the file, then use Import GGUF….")
        }
        if host == "dropbox.com" || host == "www.dropbox.com" {
            // Edited as encoded text, so an rlkey such as a%2Bb keeps its encoding.
            var items = (c.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
            items.removeAll { $0 == "dl" || $0.hasPrefix("dl=") }
            items.append("dl=1")
            c.percentEncodedQuery = items.joined(separator: "&")
        }
        if ["huggingface.co", "www.huggingface.co", "hf.co"].contains(host) {
            // /OWNER/REPO/blob/REV/FILE, or /datasets/OWNER/REPO/blob/... (also spaces/)
            var segs = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let i = segs.count > 1 && ["datasets", "spaces"].contains(segs[1]) ? 4 : 3
            if segs.count > i + 2, segs[i] == "blob" {
                segs[i] = "resolve"
                c.percentEncodedPath = segs.joined(separator: "/")
            }
        }
        guard let url = c.url else { throw Failure(message: "Not a valid link: \(input)") }
        return url
    }

    /// The scheme a pasted link starts with, lower-cased, or nil when it has none
    /// ("example.org/m.gguf", "example.org:8443/m.gguf").
    private static func scheme(of s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let head = s[..<colon]
        guard let first = head.first, first.isASCII, first.isLetter,
              head.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        let rest = s[s.index(after: colon)...]
        if !rest.hasPrefix("//"), rest.first?.isNumber == true { return nil }   // host:port
        return head.lowercased()
    }

    static func isHTTPS(_ url: URL?) -> Bool { url?.scheme?.lowercased() == "https" }

    /// The link as the log records it: no query (Dropbox keys, signatures) and no fragment.
    static func redacted(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "a link" }
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        return c.string ?? url.host ?? "a link"
    }

    /// The size the server reports for `url` (a HEAD request, following https redirects only), if any.
    static func contentLength(of url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.shared.data(for: req, delegate: HTTPSOnlyRedirects()),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              isHTTPS(http.url), http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// Space on a volume. `free` is what the volume has now (the figure `df` shows);
    /// `withReclaimable` also counts space macOS can reclaim on demand, such as local snapshots
    /// and cached files, which it may not free in time for a large write.
    struct Space {
        let free: Int64
        let withReclaimable: Int64

        /// "4 GB free", plus the reclaimable figure when it is larger.
        var text: String {
            "\(bytes(free)) free" + (withReclaimable > free ? ", or \(bytes(withReclaimable)) counting space macOS can reclaim" : "")
        }
    }

    /// The space on the volume holding `dir`, or nil when it cannot be read.
    static func space(in dir: URL) -> Space? {
        // A fresh URL, so the volume's free space is not a cached value.
        let fresh = URL(fileURLWithPath: dir.path, isDirectory: true)
        guard let v = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let free = v.volumeAvailableCapacity else { return nil }
        let now = Int64(free)
        return Space(free: now, withReclaimable: max(now, v.volumeAvailableCapacityForImportantUsage ?? now))
    }

    /// How the space on a volume compares with the bytes a download needs: `tight` when only
    /// the space macOS can reclaim makes it fit, `short` when even that does not.
    enum Room {
        case unknown, enough(Space), tight(Space), short(Space)
    }

    static func room(for need: Int64, in dir: URL) -> Room {
        guard let sp = space(in: dir) else { return .unknown }
        if sp.free >= need { return .enough(sp) }
        return sp.withReclaimable >= need ? .tight(sp) : .short(sp)
    }

    /// Checks that the volume holding `dir` has room for a download of `size` bytes, the two
    /// copies Ollama writes while importing it, and 1 GB. Throws when it does not, even
    /// counting the space macOS can reclaim; returns a warning for the caller to confirm when
    /// only that reclaimable space makes it fit; returns nil when the space is enough or cannot
    /// be read. The models store is assumed to be on the same volume, as the bundled store is.
    static func checkSpace(for size: Int64, in dir: URL) throws -> String? {
        let (copies, o1) = size.multipliedReportingOverflow(by: copiesNeeded)
        let (need, o2) = copies.addingReportingOverflow(reserve)
        if o1 || o2 {
            throw Failure(message: "Not enough disk space. The server gives the file's size as \(bytes(size)), more than any disk holds.")
        }
        let what = "The file is \(bytes(size)); downloading and importing it needs \(bytes(need)) free (the file, the two copies Ollama writes while importing it, and 1 GB to spare)."
        switch room(for: need, in: dir) {
        case .unknown, .enough:
            return nil
        case .short(let sp):
            throw Failure(message: "Not enough disk space. \(what) The disk has \(sp.text).")
        case .tight(let sp):
            return "\(what) The disk has \(bytes(sp.free)) free now. macOS reports \(bytes(sp.withReclaimable)) counting space it can reclaim, such as local snapshots and cached files, but it may not free that space in time, and the download or the import can then fail part-way."
        }
    }

    static func httpFailure(_ code: Int) -> Failure {
        let hint = [401, 403].contains(code) ? " The file may need a login, or the link may have expired." : ""
        return Failure(message: "The server answered HTTP \(code).\(hint)")
    }

    /// A safe local name for a downloaded file: letters, digits, spaces, '.', '_' and '-' only
    /// (anything else becomes '_'), no leading '.', '-' or space, and a .gguf extension.
    static func sanitizedFileName(_ raw: String) -> String {
        let kept: Set<Unicode.GeneralCategory> = [
            .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
        ]
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            scalars.append(kept.contains(s.properties.generalCategory) || " ._-".unicodeScalars.contains(s) ? s : "_")
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        while let first = name.first, ".- ".contains(first) { name.removeFirst() }
        while name.utf8.count > 200 { name.removeLast() }      // file names are limited to 255 bytes
        if name.isEmpty { name = "model" }
        return name + ".gguf"
    }

    /// Downloads `url` into `dir`, reporting (bytes written, bytes expected or -1). Cancelling
    /// the calling task cancels the transfer. `expectedSize` is the size that already passed
    /// `checkSpace`, if the server reported one. Returns the saved file.
    static func download(_ url: URL, into dir: URL, expectedSize: Int64? = nil,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let delegate = Transfer(requested: url, dir: dir, checkedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                delegate.wait(c)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Follows a redirect only when it stays on https.
    private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(isHTTPS(request.url) ? request : nil)
        }
    }

    /// URLSession delegate for one download. Callbacks arrive on the session's serial queue.
    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let requested: URL
        let dir: URL
        let checkedSize: Int64?
        let progress: @Sendable (Int64, Int64) -> Void
        private var saved: Result<URL, Error>?
        private var stopReason: Error?           // why this delegate stopped the transfer, if it did
        private var sawData = false
        private var lastReport = Date.distantPast
        private var lastSpaceCheck = Date.distantPast
        // A cancel can complete the task before the caller starts waiting, so the result and the
        // waiting continuation meet under a lock, whichever comes first.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var outcome: Result<URL, Error>?

        func wait(_ c: CheckedContinuation<URL, Error>) {
            lock.lock()
            if let outcome { lock.unlock(); c.resume(with: outcome); return }
            continuation = c
            lock.unlock()
        }

        private func finish(_ r: Result<URL, Error>) {
            lock.lock()
            guard let c = continuation else { outcome = r; lock.unlock(); return }
            continuation = nil
            lock.unlock()
            c.resume(with: r)
        }

        init(requested: URL, dir: URL, checkedSize: Int64?, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.requested = requested
            self.dir = dir
            self.checkedSize = checkedSize
            self.progress = progress
        }

        private func stop(_ task: URLSessionTask, _ reason: Error) {
            if stopReason == nil { stopReason = reason }
            task.cancel()
        }

        /// The https-only rule holds for every hop, not only for the pasted link.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard isHTTPS(request.url) else {
                stop(task, Failure(message: "The link redirected to a non-https address (\(request.url?.scheme ?? "no scheme")), so the download was stopped."))
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
            if !sawData {
                sawData = true
                // An error page is not worth downloading in full.
                if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return stop(downloadTask, httpFailure(http.statusCode))
                }
                // The size the download itself announces, when the HEAD request gave none or less.
                // Space that only macOS's reclaiming makes enough is not asked about here; the
                // floor check below stops the transfer if the disk really fills.
                if totalBytesExpectedToWrite > (checkedSize ?? 0) {
                    do {
                        if try checkSpace(for: totalBytesExpectedToWrite, in: dir) != nil {
                            AppLog.write("download: the announced \(bytes(totalBytesExpectedToWrite)) fits only with space macOS can reclaim; going on")
                        }
                    } catch { return stop(downloadTask, error) }
                }
            }
            let announced = max(checkedSize ?? 0, totalBytesExpectedToWrite)
            if announced > 0, totalBytesWritten > announced {
                return stop(downloadTask, Failure(message: "The server sent more than the \(f(announced)) it announced, so the download was stopped."))
            }
            let now = Date()
            if now.timeIntervalSince(lastSpaceCheck) >= 1 {
                lastSpaceCheck = now
                if let sp = space(in: dir), sp.free < reserve {
                    return stop(downloadTask, Failure(message: "The disk is almost full (\(f(sp.free)) free), so the download was stopped."))
                }
            }
            guard now.timeIntervalSince(lastReport) >= 0.2 else { return }   // a few UI updates a second
            lastReport = now
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (checkedSize ?? -1))
        }

        /// The temporary file is deleted when this returns, so it is moved into place here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw httpFailure(http.statusCode)
                }
                // The link's own file name when it has one (Dropbox, Hugging Face); else the server's.
                let raw = requested.pathExtension.lowercased() == "gguf"
                    ? requested.lastPathComponent
                    : (downloadTask.response?.suggestedFilename ?? requested.lastPathComponent)
                let name = sanitizedFileName(raw)
                let stem = String(name.dropLast(5))
                var dest = dir.appendingPathComponent(name)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(stem)-\(n).gguf")
                    n += 1
                }
                try FileManager.default.moveItem(at: location, to: dest)
                saved = .success(dest)
            } catch {
                saved = .failure(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<URL, Error>
            if let stopReason { result = .failure(stopReason) }
            else if let error { result = .failure(error) }
            else { result = saved ?? .failure(Failure(message: "The download ended without a file.")) }
            if case .failure = result, case .success(let file)? = saved { try? FileManager.default.removeItem(at: file) }
            finish(result)
        }
    }
}
