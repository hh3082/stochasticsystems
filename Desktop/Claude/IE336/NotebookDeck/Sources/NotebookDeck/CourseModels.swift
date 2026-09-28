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

/// The course models listed at the top of the Models window. The list is read from
/// Contents/Resources/course_models.json, which build.sh copies from Resources/; the same list
/// is compiled in below for a bundle whose file is missing or malformed. It is never fetched
/// from the network.
enum CourseModels {
    static let builtIn: [CourseModel] = [
        CourseModel(name: "qwen2.5:0.5b", source: "hf.co/purdue-ie336/qwen2.5-0.5b-instruct-GGUF:Q4_K_M", size: 397_807_936),
        CourseModel(name: "qwen2.5:3b", source: "hf.co/purdue-ie336/qwen2.5-3b-instruct-GGUF:Q4_K_M", size: 1_929_903_008),
        CourseModel(name: "qwen2.5-3b-distilled", source: "hf.co/purdue-ie336/qwen2.5-3b-irreducibility-GGUF:Q8_0", size: 3_285_475_712),
    ]

    static let fileName = "course_models.json"

    /// The list the app uses, read once.
    static let current: [CourseModel] = load()

    /// The largest size accepted in the file (1 TB). A larger one marks the file as malformed,
    /// and sizes added up for Download All cannot overflow.
    static let maxSize: Int64 = 1_000_000_000_000

    /// The list in the bundle's course_models.json, or the built-in list when the file is
    /// missing or malformed.
    static func load(from url: URL? = Bundle.main.url(forResource: "course_models", withExtension: "json")) -> [CourseModel] {
        guard let url else {
            AppLog.write("course models: no \(fileName) in the app; using the built-in list")
            return builtIn
        }
        do {
            let list = try parse(Data(contentsOf: url))
            AppLog.write("course models: \(list.count) read from \(url.path)")
            return list
        } catch {
            AppLog.write("course models: \(url.path) is unusable (\(error.localizedDescription)); using the built-in list")
            return builtIn
        }
    }

    struct Malformed: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Decodes a JSON array of {name, source, size} and checks every entry: both names valid for
    /// Ollama, the name not the source itself, a size from 1 byte to 1 TB, and no model listed
    /// twice. Names are compared as Ollama does, ignoring case and a ":latest" tag.
    static func parse(_ data: Data) throws -> [CourseModel] {
        let list = try JSONDecoder().decode([CourseModel].self, from: data)
        guard !list.isEmpty else { throw Malformed(reason: "the list is empty") }
        var seen = Set<String>()
        for m in list {
            guard OllamaServer.isValidModelName(m.name) else { throw Malformed(reason: "\(m.name) is not a valid model name") }
            guard OllamaServer.isValidModelName(m.source) else { throw Malformed(reason: "\(m.source) is not a valid model name") }
            guard CourseModel.key(m.name) != CourseModel.key(m.source) else { throw Malformed(reason: "\(m.name) is its own source") }
            guard m.size > 0, m.size <= maxSize else { throw Malformed(reason: "\(m.name) has size \(m.size)") }
            guard seen.insert(CourseModel.key(m.name)).inserted else { throw Malformed(reason: "\(m.name) is listed twice") }
        }
        return list
    }
}
