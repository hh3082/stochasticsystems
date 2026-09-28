import Foundation

/// A Hugging Face model repo in the form Ollama pulls it: hf.co/OWNER/REPO[:TAG], where the
/// tag is a quantization name (Q4_K_M) or the full name of one .gguf file in the repo.
struct HFRepoRef: Equatable {
    let owner: String
    let repo: String
    var tag: String?
    /// The file a /blob/ or /resolve/ link pointed at, as a path inside the repo.
    var file: String?

    var repoName: String { "hf.co/\(owner)/\(repo)" }
    func ollamaName(tag: String?) -> String { repoName + (tag.map { ":\($0)" } ?? "") }

    static let formatHint = "Enter hf.co/OWNER/REPO, OWNER/REPO, either with an optional :TAG, or a huggingface.co link to the repo or to one .gguf file."

    /// Accepts hf.co/OWNER/REPO[:TAG], huggingface.co/OWNER/REPO[:TAG], OWNER/REPO[:TAG], and
    /// https://huggingface.co/OWNER/REPO, optionally followed by /tree/..., or by
    /// /blob/REVISION/FILE.gguf (or /resolve/...), which selects that file. A link must be to
    /// Hugging Face.
    init?(parsing input: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var isLink = false
        for scheme in ["https://", "http://"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
            isLink = true
        }
        guard !s.contains("://") else { return nil }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        var parts = s.split(separator: "/").map(String.init)
        if let host = parts.first?.lowercased(), ["hf.co", "huggingface.co", "www.huggingface.co"].contains(host) {
            parts.removeFirst()
        } else if isLink {
            return nil
        }
        guard parts.count >= 2, !["datasets", "spaces", "models"].contains(parts[0].lowercased()) else { return nil }
        owner = parts[0]
        var repo = parts[1]
        if let colon = repo.firstIndex(of: ":") {
            let t = String(repo[repo.index(after: colon)...])
            guard t.isEmpty || Self.isValidTag(t) else { return nil }
            tag = t.isEmpty ? nil : t
            repo = String(repo[..<colon])
        }
        self.repo = repo
        guard Self.isValidName(owner, isOwner: true), Self.isValidName(repo, isOwner: false) else { return nil }
        if parts.count > 2 {
            switch parts[2] {
            case "tree":
                break
            case "blob", "resolve":
                guard tag == nil, parts.count >= 5 else { return nil }
                let path = parts[4...].joined(separator: "/")
                let decoded = path.removingPercentEncoding ?? path
                guard decoded.lowercased().hasSuffix(".gguf") else { return nil }
                file = decoded
                tag = HFFile.tag(forFileName: (decoded as NSString).lastPathComponent)
            default:
                return nil
            }
        }
    }

    /// Hugging Face repo names: letters, digits, '-', '_' and '.', with no '-' or '.' at either
    /// end and no "--" or "..". Owner names take no '.', which Ollama does not accept there.
    private static func isValidName(_ s: String, isOwner: Bool) -> Bool {
        guard let first = s.first, let last = s.last, s.count <= 96, !"-.".contains(first), !"-.".contains(last),
              !s.contains("--"), !s.contains("..") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || ($0 == "." && !isOwner)) }
    }

    /// Ollama tags: a letter, digit or '_', then letters, digits, '_', '-' and '.'.
    private static func isValidTag(_ t: String) -> Bool {
        guard let first = t.first, t.count <= 128, first.isASCII, first.isLetter || first.isNumber || first == "_" else { return false }
        return t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
    }
}

/// One .gguf file in a Hugging Face repo, with the Ollama tag that selects it.
struct HFFile: Identifiable, Hashable {
    let path: String
    let size: Int64
    var tag: String
    var id: String { path }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// llama.cpp quantization names, matched as a whole word in a file name, case-insensitively
    /// (Unsloth's "UD-" dynamic quants included). A name may not run on into letters, digits or
    /// '_', so "Q4_K_Mx" is not read as Q4_K.
    private static let quantPattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9])((?:UD-)?(?:I?Q[1-8]_K_(?:XXS|XS|XL|S|M|L)|IQ[1-4]_(?:XXS|XS|NL|S|M)|Q[2-8]_K|Q[4-8]_[01](?:_[48]_[48])?|TQ[12]_0|MXFP4|BF16|F16|F32))(?![A-Za-z0-9_])"#,
        options: [.caseInsensitive])

    /// The quantization name in `name` (upper-cased), or nil when it contains none.
    static func quantization(inFileName name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = quantPattern.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) else { return nil }
        return name[r].uppercased()
    }

    /// The tag for a file: its quantization name, else the full file name. Hugging Face refuses
    /// a few quantization names as tags; the Download button then uses the full file name.
    static func tag(forFileName name: String) -> String {
        quantization(inFileName: name) ?? name
    }
}

enum HuggingFace {
    struct LookUpError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Listing {
        let files: [HFFile]
        let gated: Bool
        /// Quantizations left out because they are split into parts.
        let splitCount: Int
    }

    /// One part of a GGUF split into several files: NAME-00001-of-00003.gguf.
    private static let splitPattern = try! NSRegularExpression(pattern: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.caseInsensitive])

    static func isSplitPart(_ path: String) -> Bool {
        splitPattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func splitPartNote(_ name: String) -> String {
        "\(name) is one part of a GGUF split into several files, which Ollama cannot download from Hugging Face. Pick a quantization stored as a single file, or download the parts, merge them with llama.cpp's gguf-split, and use Import GGUF…."
    }

    /// Lists the .gguf files of a public model repo, with their sizes and tags. Files split
    /// into parts are left out, since Ollama cannot pull them through Hugging Face.
    static func lookUp(_ ref: HFRepoRef) async throws -> Listing {
        var comps = URLComponents(string: "https://huggingface.co")!
        comps.path = "/api/models/\(ref.owner)/\(ref.repo)"
        comps.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            break
        case 401, 403, 404:
            // Hugging Face answers 401 both for private repos and for repos that do not exist.
            throw LookUpError(message: "Hugging Face has no public repo \(ref.repoName): it does not exist, or it is private (HTTP \(code)). Only public repos can be downloaded here.")
        default:
            throw LookUpError(message: "Hugging Face answered HTTP \(code) for \(ref.repoName).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let siblings = obj["siblings"] as? [[String: Any]] else {
            throw LookUpError(message: "Hugging Face sent an unexpected answer for \(ref.repoName).")
        }
        // mmproj files are vision projectors that Ollama fetches with the model; they are not models.
        let all: [HFFile] = siblings.compactMap { s in
            guard let path = s["rfilename"] as? String, path.lowercased().hasSuffix(".gguf"),
                  !path.lowercased().contains("mmproj") else { return nil }
            let size = (s["size"] as? NSNumber) ?? ((s["lfs"] as? [String: Any])?["size"] as? NSNumber)
            let name = (path as NSString).lastPathComponent
            return HFFile(path: path, size: size?.int64Value ?? 0, tag: HFFile.tag(forFileName: name))
        }
        let parts = all.filter { isSplitPart($0.path) }
        var files = all.filter { !isSplitPart($0.path) }
        // One split quantization per distinct name before the -0000N-of-0000M suffix.
        let splitCount = Set(parts.map { splitPattern.stringByReplacingMatches(in: $0.path, range: NSRange($0.path.startIndex..., in: $0.path), withTemplate: "").lowercased() }).count
        guard !files.isEmpty else {
            if !parts.isEmpty {
                throw LookUpError(message: "\(ref.repoName) has its GGUF files only split into parts, which Ollama cannot download from Hugging Face. Download the parts, merge them with llama.cpp's gguf-split, and use Import GGUF….")
            }
            throw LookUpError(message: "\(ref.repoName) has no .gguf file. Ollama can download only GGUF repos; look for one whose name ends in -GGUF.")
        }
        // Two files with the same quantization (variants in folders, for instance): use the full file names.
        let counts = Dictionary(files.map { ($0.tag.uppercased(), 1) }, uniquingKeysWith: +)
        for i in files.indices where counts[files[i].tag.uppercased(), default: 0] > 1 {
            files[i].tag = (files[i].path as NSString).lastPathComponent
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let gated = (obj["gated"] as? Bool) ?? (obj["gated"] is String)
        return Listing(files: files, gated: gated, splitCount: splitCount)
    }

    /// Size of the model file that Hugging Face's registry for Ollama serves under `tag`, or nil
    /// when it refuses the tag or cannot be reached. The registry refuses some quantization
    /// names that files carry (Q4_K_L, Q5_K_L), while it accepts every full file name.
    static func modelSize(_ ref: HFRepoRef, tag: String) async -> Int64? {
        var comps = URLComponents(string: "https://huggingface.co")!
        comps.path = "/v2/\(ref.owner)/\(ref.repo)/manifests/\(tag)"
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let layers = obj["layers"] as? [[String: Any]],
              let model = layers.first(where: { $0["mediaType"] as? String == "application/vnd.ollama.image.model" }),
              let size = (model["size"] as? NSNumber)?.int64Value else { return nil }
        return size
    }
}
