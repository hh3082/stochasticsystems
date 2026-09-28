import Foundation

/// Reads the metadata of a GGUF model file: the key-value pairs that precede the tensors.
/// The file is streamed from disk; only the string values asked for are kept, and every
/// other value, including the tokenizer's arrays of 150k strings, is skipped.
///
/// Layout (GGUF versions 2 and 3, little-endian): "GGUF", u32 version, u64 tensor_count,
/// u64 kv_count, then kv_count entries { u64 key length, key bytes, u32 type, value }.
/// Types: 0 uint8, 1 int8, 2 uint16, 3 int16, 4 uint32, 5 int32, 6 float32, 7 bool,
/// 8 string (u64 length + bytes), 9 array (u32 element type, u64 count, elements),
/// 10 uint64, 11 int64, 12 float64.
enum GGUF {
    struct FormatError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Not a readable GGUF file: \(reason)." }
    }

    static let maxKeyLength: UInt64 = 65_535
    static let maxStringLength: UInt64 = 16 << 20        // for a value read into memory, not one skipped
    static let maxKeyValueCount: UInt64 = 1 << 20
    static let maxArrayDepth = 4

    /// True when the file starts with the four bytes "GGUF".
    static func hasMagic(_ file: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    /// The chat template the file carries (`tokenizer.chat_template`), or nil if it has none.
    static func chatTemplate(in file: URL) throws -> String? {
        try strings(for: ["tokenizer.chat_template"], in: file)["tokenizer.chat_template"]
    }

    /// The string values stored under `keys`; keys that are absent, or hold another type, are
    /// left out. Throws on anything inconsistent with the format.
    static func strings(for keys: Set<String>, in file: URL) throws -> [String: String] {
        let r = try Reader(file)
        defer { r.close() }
        guard try r.bytes(4) == Array("GGUF".utf8) else { throw FormatError(reason: "it does not start with GGUF") }
        let version = try r.u32()
        guard version == 2 || version == 3 else { throw FormatError(reason: "unsupported version \(version)") }
        _ = try r.u64()                                   // tensor count; the tensors are not read
        let kvCount = try r.u64()
        // Each entry takes at least 13 bytes (key length, one key byte, type, one value byte).
        guard kvCount <= maxKeyValueCount, kvCount <= r.remaining / 13 else {
            throw FormatError(reason: "implausible key count \(kvCount)")
        }
        var found: [String: String] = [:]
        for _ in 0..<kvCount {
            let keyLength = try r.u64()
            guard keyLength > 0, keyLength <= maxKeyLength else { throw FormatError(reason: "key length \(keyLength)") }
            guard let key = String(bytes: try r.bytes(Int(keyLength)), encoding: .utf8) else {
                throw FormatError(reason: "a key is not UTF-8")
            }
            let type = try r.u32()
            if type == 8, keys.contains(key) {
                let length = try r.u64()
                guard length <= maxStringLength else { throw FormatError(reason: "\(key) is \(length) bytes long") }
                guard let value = String(bytes: try r.bytes(Int(length)), encoding: .utf8) else {
                    throw FormatError(reason: "\(key) is not UTF-8")
                }
                found[key] = value
                if found.count == keys.count { break }
            } else {
                try skipValue(type: type, r, depth: 0)
            }
        }
        return found
    }

    /// Size in bytes of a fixed-size value type, nil for strings and arrays.
    private static func fixedSize(_ type: UInt32) -> UInt64? {
        switch type {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil
        }
    }

    private static func skipValue(type: UInt32, _ r: Reader, depth: Int) throws {
        if let size = fixedSize(type) { try r.skip(size); return }
        switch type {
        case 8:
            // A skipped string is never read, so only the end of the file bounds it.
            try r.skip(try r.u64())
        case 9:
            guard depth < maxArrayDepth else { throw FormatError(reason: "arrays nested too deeply") }
            let elementType = try r.u32()
            let count = try r.u64()
            if let size = fixedSize(elementType) {
                guard count <= r.remaining / size else { throw FormatError(reason: "an array runs past the end of the file") }
                try r.skip(count * size)
            } else if elementType == 8 || elementType == 9 {
                // Every string takes at least its 8-byte length; every nested array at least 12 bytes.
                guard count <= r.remaining / (elementType == 8 ? 8 : 12) else {
                    throw FormatError(reason: "an array runs past the end of the file")
                }
                for _ in 0..<count { try skipValue(type: elementType, r, depth: depth + 1) }
            } else {
                throw FormatError(reason: "unknown array element type \(elementType)")
            }
        default:
            throw FormatError(reason: "unknown value type \(type)")
        }
    }

    /// Sequential little-endian reader over a file, through a 1 MB buffer. Skips beyond the
    /// buffer become a seek, so large values are never read.
    private final class Reader {
        private let handle: FileHandle
        private let size: UInt64
        private var buffer: [UInt8] = []
        private var pos = 0                   // index of the next byte in `buffer`
        private var bufferStart: UInt64 = 0   // file offset of buffer[0]
        private static let chunk = 1 << 20

        init(_ file: URL) throws {
            handle = try FileHandle(forReadingFrom: file)
            size = try handle.seekToEnd()
        }

        func close() { try? handle.close() }

        var offset: UInt64 { bufferStart + UInt64(pos) }
        var remaining: UInt64 { size - offset }

        private func fill(_ n: Int) throws {
            if buffer.count - pos >= n { return }
            guard UInt64(n) <= remaining else { throw FormatError(reason: "the file ends early") }
            let start = offset
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: max(n, Self.chunk)) ?? Data()
            guard data.count >= n else { throw FormatError(reason: "the file ends early") }
            buffer = [UInt8](data)
            bufferStart = start
            pos = 0
        }

        func bytes(_ n: Int) throws -> [UInt8] {
            try fill(n)
            defer { pos += n }
            return Array(buffer[pos..<pos + n])
        }

        private func integer<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            try fill(n)
            var v: T = 0
            for i in 0..<n { v |= T(buffer[pos + i]) << (8 * i) }
            pos += n
            return v
        }

        func u32() throws -> UInt32 { try integer(UInt32.self) }
        func u64() throws -> UInt64 { try integer(UInt64.self) }

        func skip(_ n: UInt64) throws {
            guard n <= remaining else { throw FormatError(reason: "a value runs past the end of the file") }
            if n <= UInt64(buffer.count - pos) {
                pos += Int(n)
            } else {
                bufferStart = offset + n
                buffer = []
                pos = 0
            }
        }
    }
}
