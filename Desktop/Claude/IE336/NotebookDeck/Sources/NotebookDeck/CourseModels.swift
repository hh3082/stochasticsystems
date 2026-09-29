import Foundation

/// A model the lab notebooks use: the name the notebooks ask Ollama for, the Hugging Face repo
/// it is pulled from, and the size of its GGUF file in bytes.
struct CourseModel: Codable, Identifiable, Hashable {
    let name: String
    let source: String
    let size: Int64
    var id: String { name }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// True when `names` (as /api/tags lists them) contain this model, as `name` or `name:latest`.
    func isInstalled(in names: [String]) -> Bool {
        names.contains { $0 == name || $0 == name + ":latest" }
    }

    /// The model `n` names for Ollama, for comparing names: lower case, without a ":latest" tag.
    static func key(_ n: String) -> String {
        let k = n.lowercased()
        return k.hasSuffix(":latest") ? String(k.dropLast(7)) : k
    }
}

/// The course models listed at the top of the Models window.
///
/// The list lives on Hugging Face (`remoteURL`, in the dataset purdue-ie336/course-models), so
/// editing that one file changes the list of every copy of the app. Each time the Models window
/// refreshes, ModelManager fetches it (`fetch`) and passes the result to `choose`, which checks
/// it (`parse`) and saves a valid list to `savedURL`. When the fetch fails or the list is
/// invalid, the saved copy is used if it is valid, then the course_models.json that build.sh
/// copies into Contents/Resources, then the list compiled in below.
enum CourseModels {
    static let builtIn: [CourseModel] = [
        CourseModel(name: "qwen2.5:0.5b", source: "hf.co/purdue-ie336/qwen2.5-0.5b-instruct-GGUF:Q4_K_M", size: 397_807_936),
        CourseModel(name: "qwen2.5:3b", source: "hf.co/purdue-ie336/qwen2.5-3b-instruct-GGUF:Q4_K_M", size: 1_929_903_008),
        CourseModel(name: "qwen2.5-3b-markov-classes", source: "hf.co/purdue-ie336/qwen2.5-3b-markov-classes-GGUF:Q6_K", size: 2_538_158_464),
    ]

    static let fileName = "course_models.json"

    /// The list on Hugging Face. Hugging Face answers with a redirect to /api/resolve-cache/...
    /// on the same host.
    static let remoteURL = URL(string: "https://huggingface.co/datasets/purdue-ie336/course-models/resolve/main/course_models.json")!

    /// Where the last valid list fetched from Hugging Face is saved.
    static var savedURL: URL { BundledRuntime.supportDir.appendingPathComponent(fileName) }

    /// The list in the app's Contents/Resources, if the bundle has one.
    static var bundledURL: URL? { Bundle.main.url(forResource: "course_models", withExtension: "json") }

    /// Limits a list must meet: 1 to `maxCount` entries, sizes from 1 byte to `maxSize` (200 GB),
    /// and at most `maxBytes` of JSON. Sizes added up for Download All cannot overflow.
    static let maxCount = 50
    static let maxSize: Int64 = 200_000_000_000
    static let maxBytes = 64 * 1024

    /// Seconds the whole fetch may take, redirects included.
    static let timeout: TimeInterval = 5

    /// Every source must lie in the course's organization on Hugging Face.
    static let sourcePrefix = "hf.co/purdue-ie336/"

    /// Where the list in use came from.
    enum Origin: Equatable {
        case remote, saved, bundled, compiledIn

        /// The caption under the Course models rows.
        var caption: String {
            switch self {
            case .remote: return "List from Hugging Face"
            case .saved: return "Saved list (offline)"
            case .bundled, .compiledIn: return "List built into the app"
            }
        }
    }

    struct Choice: Equatable {
        let list: [CourseModel]
        let origin: Origin
    }

    // MARK: The list in use

    /// The list in use when the app starts, before any fetch: the saved copy, else the app's own.
    static let atLaunch: Choice = local(why: "at launch")

    /// The list in use: `atLaunch` until ModelManager sets another. The toolbar's status line
    /// reads it from any thread.
    static var current: [CourseModel] { active.list ?? atLaunch.list }

    static func setCurrent(_ list: [CourseModel]) { active.list = list }

    private static let active = ActiveList()

    private final class ActiveList: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [CourseModel]?
        var list: [CourseModel]? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    // MARK: Choosing a list

    /// The list to use after a fetch. A valid fetched list is used and saved atomically to
    /// `saved` (unless the file already holds the same bytes); otherwise `local` decides. Logs
    /// which list is used and why.
    static func choose(fetched: Result<Data, Error>, saved: URL = savedURL, bundled: URL? = bundledURL) -> Choice {
        let why: String
        switch fetched {
        case .success(let data):
            do {
                let list = try parse(data)
                AppLog.write("course models: using the list from Hugging Face (\(summary(list)))" + save(data, to: saved))
                return Choice(list: list, origin: .remote)
            } catch {
                why = "the list from Hugging Face is invalid (\(describe(error)))"
            }
        case .failure(let error):
            why = "fetching the list from Hugging Face failed (\(describe(error)))"
        }
        return local(why: why, saved: saved, bundled: bundled)
    }

    /// The list to use without the network: the file at `saved` when it exists and is valid,
    /// else the file at `bundled`, else `builtIn`. `why` explains, in the log, why no fetched
    /// list is used.
    static func local(why: String, saved: URL = savedURL, bundled: URL? = bundledURL) -> Choice {
        var passed: [String] = []
        if FileManager.default.fileExists(atPath: saved.path) {
            do {
                let list = try parse(readCapped(saved))
                AppLog.write("course models: \(why); using the saved list \(saved.path) (\(summary(list)))")
                return Choice(list: list, origin: .saved)
            } catch {
                passed.append("the saved list \(saved.path) is unusable (\(describe(error)))")
            }
        } else {
            passed.append("no saved list")
        }
        if let bundled {
            do {
                let list = try parse(readCapped(bundled))
                AppLog.write("course models: \(why); " + (passed + ["using the list built into the app, \(bundled.path) (\(summary(list)))"]).joined(separator: "; "))
                return Choice(list: list, origin: .bundled)
            } catch {
                passed.append("\(bundled.path) is unusable (\(describe(error)))")
            }
        } else {
            passed.append("no \(fileName) in the app")
        }
        AppLog.write("course models: \(why); " + (passed + ["using the list compiled into the app (\(summary(builtIn)))"]).joined(separator: "; "))
        return Choice(list: builtIn, origin: .compiledIn)
    }

    /// Writes `data` to `url` atomically unless the file already holds it; returns a note for the log.
    private static func save(_ data: Data, to url: URL) -> String {
        if let old = try? readCapped(url), old == data { return "; the saved copy \(url.path) is the same" }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return "; saved it to \(url.path)"
        } catch {
            return "; saving it to \(url.path) failed (\(error.localizedDescription))"
        }
    }

    /// The contents of a local list file, refused when it is larger than `maxBytes`.
    private static func readCapped(_ url: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let data = try h.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw Malformed(reason: "the file is larger than 64 KB") }
        return data
    }

    private static func summary(_ list: [CourseModel]) -> String {
        "\(list.count) model\(list.count == 1 ? "" : "s"): " + list.map(\.name).joined(separator: ", ")
    }

    // MARK: Fetching

    struct FetchFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Fetches `url` with an ephemeral session (no cookies, no cache, no stored credentials),
    /// allowing `timeout` seconds for the whole transfer. A redirect is followed only when
    /// `isAllowedRedirect` accepts its target; any other redirect aborts the fetch. Throws
    /// unless the answer is status 200 with a body of at most `maxBytes`.
    ///
    /// Accepted risk: `maxBytes` limits what this function reads, not the memory the process
    /// uses. URLSession decodes a compressed body (gzip, deflate, and brotli although only the
    /// first two are requested) as it arrives, before any byte reaches this code, so a small
    /// compressed answer can inflate to hundreds of megabytes before the cap throws. Refusing
    /// on Content-Encoding, cancelling in didReceive(response), and sending
    /// `Accept-Encoding: identity` were each tried and none bounds it. Only an answer from
    /// huggingface.co over TLS can do this, and the process recovers once the fetch fails.
    static func fetch(_ url: URL = remoteURL, timeout: TimeInterval = timeout) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let redirects = RedirectCheck()
        let session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if let refused = redirects.refused { throw FetchFailure(reason: "refused a redirect to \(refused)") }
            throw error
        }
        if let refused = redirects.refused { throw FetchFailure(reason: "refused a redirect to \(refused)") }
        guard let http = response as? HTTPURLResponse else { throw FetchFailure(reason: "the answer is not HTTP") }
        guard http.statusCode == 200 else { throw FetchFailure(reason: "HTTP status \(http.statusCode)") }
        guard http.expectedContentLength <= Int64(maxBytes) else {
            throw FetchFailure(reason: "the list is \(http.expectedContentLength) bytes, more than 64 KB")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maxBytes else { throw FetchFailure(reason: "the list is larger than 64 KB") }
        }
        return data
    }

    /// True for an https address on huggingface.co or one of its subdomains, on the default
    /// port and without a user name or password. The host is checked as written, before any
    /// percent-decoding: it may hold only ASCII letters, digits, '.' and '-', with no empty
    /// label, so "evil.com%2F.huggingface.co" or ".huggingface.co" is refused here rather
    /// than left to CFNetwork's own host check.
    static func isAllowedRedirect(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: true)?.lowercased() else { return false }
        let hostBytes = Array(host.utf8)
        guard hostBytes.allSatisfy({ b in
            (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == 0x2E || b == 0x2D
        }) else { return false }
        guard !hostBytes.split(separator: 0x2E, omittingEmptySubsequences: false).contains(where: { $0.isEmpty }) else {
            return false
        }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co")
    }

    /// Follows the redirects `isAllowedRedirect` accepts and cancels the fetch at any other.
    private final class RedirectCheck: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var target: String?
        /// The redirect target that stopped the fetch, if one did.
        var refused: String? { lock.withLock { target } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if CourseModels.isAllowedRedirect(request.url) {
                completionHandler(request)
                return
            }
            let shown = request.url.map { u -> String in
                var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
                c?.query = nil
                c?.user = nil
                c?.password = nil
                return c?.string ?? "an unreadable address"
            } ?? "no address"
            lock.withLock { target = CourseModels.quoted(shown) }
            task.cancel()
            completionHandler(nil)
        }
    }

    // MARK: Checking

    struct Malformed: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Decodes a JSON array of {name, source, size} and checks it: strict JSON (`StrictJSON`),
    /// 1 to `maxCount` entries, at most `maxBytes` of JSON, and for every entry a name valid
    /// for Ollama that does not start with '-', a source matching
    /// ^hf\.co/purdue-ie336/[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?$ that is also valid for Ollama,
    /// and an integer size from 1 to `maxSize`. No model may be listed twice, and no name may
    /// be the source of any entry (its own or another's), since Download pulls a source under
    /// the source's name and then deletes that name. Names are compared as Ollama does, ignoring
    /// case and a ":latest" tag. Other fields are ignored, so a later field does not break this app.
    static func parse(_ data: Data) throws -> [CourseModel] {
        guard data.count <= maxBytes else { throw Malformed(reason: "the list is larger than 64 KB") }
        try StrictJSON.check(data)
        let list: [CourseModel]
        do {
            list = try JSONDecoder().decode([CourseModel].self, from: data)
        } catch let e as DecodingError {
            throw Malformed(reason: describe(e))
        }
        guard (1...maxCount).contains(list.count) else {
            throw Malformed(reason: "the list has \(list.count) entries; it must have 1 to \(maxCount)")
        }
        var seen = Set<String>()
        for m in list {
            let name = quoted(m.name)
            guard OllamaServer.isValidModelName(m.name), !m.name.hasPrefix("-") else {
                throw Malformed(reason: "\(name) is not a valid model name")
            }
            guard isCourseSource(m.source), OllamaServer.isValidModelName(m.source) else {
                throw Malformed(reason: "\(name) has the source \(quoted(m.source)), which is not a repo of \(sourcePrefix)")
            }
            guard (1...maxSize).contains(m.size) else { throw Malformed(reason: "\(name) has size \(m.size)") }
            guard seen.insert(CourseModel.key(m.name)).inserted else { throw Malformed(reason: "\(name) is listed twice") }
        }
        let sources = Set(list.map { CourseModel.key($0.source) })
        for m in list where sources.contains(CourseModel.key(m.name)) {
            let own = CourseModel.key(m.name) == CourseModel.key(m.source)
            throw Malformed(reason: "\(quoted(m.name)) is " + (own ? "its own source" : "the source of another entry"))
        }
        return list
    }

    /// Checks that a list is strict JSON (RFC 8259) before JSONDecoder reads it: UTF-8 without
    /// a byte-order mark, a top-level array, no trailing comma, comment, NaN, hex number or
    /// other extension, and at most `maxDepth` levels of nesting. In each entry (an object in
    /// the top-level array) no key may appear twice, and a `size` written as a number must be
    /// an integer, with no fraction or exponent. JSONDecoder accepts trailing commas, a
    /// byte-order mark, UTF-16, and 1e3 or 1000.0 for 1000, and it keeps the first of two equal
    /// keys where Python's json keeps the last, so without this check a list could pass here
    /// and fail, or read differently, in another reader such as the Windows port.
    private struct StrictJSON {
        static let maxDepth = 64

        private let bytes: [UInt8]
        private var i = 0

        private init(_ data: Data) { bytes = [UInt8](data) }

        static func check(_ data: Data) throws {
            var s = StrictJSON(data)
            try s.list()
        }

        private enum Kind { case integer, nonInteger, other }

        private func fail(_ what: String) -> Malformed { Malformed(reason: "not strict JSON: \(what) (byte \(i + 1))") }

        private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        private static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }

        private static func isHex(_ b: UInt8) -> Bool {
            isDigit(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
        }

        private mutating func skipSpace() {
            while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 }
        }

        private mutating func list() throws {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw Malformed(reason: "not strict JSON: the list starts with a byte-order mark") }
            // Decoding with repair replaces each invalid sequence, so only valid UTF-8 comes back unchanged.
            guard Array(String(decoding: bytes, as: UTF8.self).utf8) == bytes else {
                throw Malformed(reason: "not strict JSON: the list is not valid UTF-8")
            }
            skipSpace()
            guard peek == UInt8(ascii: "[") else { throw fail("the list is not a JSON array") }
            try array(depth: 1)
            skipSpace()
            guard i == bytes.count else { throw fail("text after the list") }
        }

        /// Reads one value; a container it opens is at nesting level `depth`.
        private mutating func value(depth: Int) throws -> Kind {
            skipSpace()
            guard let b = peek else { throw fail("the list ends where a value should be") }
            switch b {
            case UInt8(ascii: "["): try array(depth: depth); return .other
            case UInt8(ascii: "{"): try object(depth: depth, entry: nil); return .other
            case UInt8(ascii: "\""): _ = try string(decode: false); return .other
            case UInt8(ascii: "t"): try literal("true"); return .other
            case UInt8(ascii: "f"): try literal("false"); return .other
            case UInt8(ascii: "n"): try literal("null"); return .other
            case UInt8(ascii: "-"), 0x30...0x39: return try number()
            default: throw fail("unexpected character")
            }
        }

        /// Reads an array. The objects in the top-level array (`depth` 1) are the entries.
        private mutating func array(depth: Int) throws {
            guard depth <= Self.maxDepth else { throw fail("nested more than \(Self.maxDepth) levels") }
            i += 1
            skipSpace()
            if peek == UInt8(ascii: "]") { i += 1; return }
            var index = 0
            while true {
                skipSpace()
                index += 1
                if depth == 1, peek == UInt8(ascii: "{") {
                    try object(depth: 2, entry: index)
                } else {
                    _ = try value(depth: depth + 1)
                }
                skipSpace()
                switch peek {
                case UInt8(ascii: ","):
                    i += 1
                    skipSpace()
                    if peek == UInt8(ascii: "]") { throw fail("a comma before ]") }
                case UInt8(ascii: "]"):
                    i += 1
                    return
                default:
                    throw fail("expected , or ] in an array")
                }
            }
        }

        /// Reads an object; `entry` numbers it (from 1) when it is an entry of the list.
        private mutating func object(depth: Int, entry: Int?) throws {
            guard depth <= Self.maxDepth else { throw fail("nested more than \(Self.maxDepth) levels") }
            i += 1
            skipSpace()
            if peek == UInt8(ascii: "}") { i += 1; return }
            var keys = Set<String>()
            while true {
                skipSpace()
                guard peek == UInt8(ascii: "\"") else {
                    throw fail(peek == UInt8(ascii: "}") ? "a comma before }" : "expected a key in double quotes")
                }
                let key = try string(decode: entry != nil)
                skipSpace()
                guard peek == UInt8(ascii: ":") else { throw fail("expected : after a key") }
                i += 1
                let kind = try value(depth: depth + 1)
                if let entry, let key {
                    guard keys.insert(key).inserted else { throw fail("entry \(entry) has the key \(CourseModels.quoted(key)) twice") }
                    if key == "size", kind == .nonInteger { throw fail("entry \(entry) has a size that is not written as an integer") }
                }
                skipSpace()
                switch peek {
                case UInt8(ascii: ","): i += 1
                case UInt8(ascii: "}"): i += 1; return
                default: throw fail("expected , or } in an object")
                }
            }
        }

        /// Reads a string; returns its value when `decode` is true.
        private mutating func string(decode: Bool) throws -> String? {
            let start = i
            i += 1
            var escaped = false
            while true {
                guard let b = peek else { throw fail("a string is not closed") }
                i += 1
                if b == UInt8(ascii: "\"") { break }
                if b < 0x20 { throw fail("a control character in a string") }
                guard b == UInt8(ascii: "\\") else { continue }
                escaped = true
                guard let e = peek else { throw fail("a string is not closed") }
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                     UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    i += 1
                case UInt8(ascii: "u"):
                    guard i + 4 < bytes.count, bytes[(i + 1)...(i + 4)].allSatisfy(Self.isHex) else {
                        throw fail("a bad \\u escape")
                    }
                    i += 5
                default:
                    throw fail("a bad escape")
                }
            }
            guard decode else { return nil }
            let raw = bytes[start..<i]
            if !escaped { return String(decoding: raw.dropFirst().dropLast(), as: UTF8.self) }
            guard let s = (try? JSONSerialization.jsonObject(with: Data(raw), options: .fragmentsAllowed)) as? String else {
                throw fail("a string that cannot be decoded")
            }
            return s
        }

        private mutating func number() throws -> Kind {
            if peek == UInt8(ascii: "-") { i += 1 }
            guard let first = peek, Self.isDigit(first) else { throw fail("a bad number") }
            i += 1
            if first == UInt8(ascii: "0") {
                if let b = peek, Self.isDigit(b) { throw fail("a number with a leading zero") }
            } else {
                while let b = peek, Self.isDigit(b) { i += 1 }
            }
            var integer = true
            if peek == UInt8(ascii: ".") {
                integer = false
                i += 1
                guard let b = peek, Self.isDigit(b) else { throw fail("a bad number") }
                while let b = peek, Self.isDigit(b) { i += 1 }
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                integer = false
                i += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
                guard let b = peek, Self.isDigit(b) else { throw fail("a bad number") }
                while let b = peek, Self.isDigit(b) { i += 1 }
            }
            return integer ? .integer : .nonInteger
        }

        private mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard bytes[i...].starts(with: w) else { throw fail("unexpected text") }
            i += w.count
        }
    }

    /// True when the whole of `s` matches ^hf\.co/purdue-ie336/[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?$.
    /// Checked byte by byte, so no trailing newline or non-ASCII character slips through.
    static func isCourseSource(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        let prefix = Array(sourcePrefix.utf8)
        guard bytes.starts(with: prefix) else { return false }
        let parts = bytes[prefix.count...].split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { b in
                (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x2E || b == 0x5F || b == 0x2D
            }
        }
    }

    /// `s` in quotes with control characters escaped, cut to 100 characters, for messages and the log.
    private static func quoted(_ s: String) -> String {
        s.count > 100 ? String(s.prefix(100)).debugDescription + "…" : s.debugDescription
    }

    /// A short reason for the log.
    private static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError { return describe(e) }
        return error.localizedDescription
    }

    private static func describe(_ e: DecodingError) -> String {
        func at(_ path: [CodingKey]) -> String {
            if path.isEmpty { return "the list" }
            return path.map { k in k.intValue.map { "entry \($0 + 1)" } ?? k.stringValue }.joined(separator: ", ")
        }
        let text: String
        switch e {
        case .typeMismatch(_, let c): text = "\(at(c.codingPath)): \(c.debugDescription)"
        case .valueNotFound(_, let c): text = "\(at(c.codingPath)): no value"
        case .keyNotFound(let k, let c): text = "\(at(c.codingPath)): no \(k.stringValue)"
        case .dataCorrupted(let c): text = c.codingPath.isEmpty ? "not valid JSON" : "\(at(c.codingPath)): \(c.debugDescription)"
        @unknown default: text = e.localizedDescription
        }
        return String(text.prefix(300))
    }
}
