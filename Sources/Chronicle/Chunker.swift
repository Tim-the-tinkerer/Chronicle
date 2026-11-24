import Compression
import CryptoKit
import Foundation

/// SplitMix64. The chunker table is derived from a fixed seed so every
/// Chronicle writes the same cuts. This is not a secret and not a hash
/// anyone should use for security.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func rotl64(_ value: UInt64, _ bits: Int) -> UInt64 {
    let shift = bits & 63
    if shift == 0 { return value }
    return (value << shift) | (value >> (64 - shift))
}

enum Gear {
    /// Documented in FORMAT.md. Changing it changes every chunk boundary.
    static let seed: UInt64 = 0xC470_41C1_C1E5_0001

    static let table: [UInt64] = {
        var mix = SplitMix64(state: seed)
        return (0..<256).map { _ in
            let value = mix.next()
            return value == 0 ? 0x9E3779B97F4A7C15 : value
        }
    }()
}

struct ChunkParams: Codable, Equatable {
    var min: Int
    var avgBits: Int
    var max: Int
    var window: Int

    static let standard = ChunkParams(min: 8 * 1024, avgBits: 15, max: 128 * 1024, window: 32)

    var mask: UInt64 {
        if avgBits <= 0 { return 0 }
        if avgBits >= 64 { return UInt64.max }
        return (UInt64(1) << UInt64(avgBits)) &- 1
    }

    func validate() throws {
        if min < 64 || max < min || max > 8 * 1024 * 1024 || avgBits < 8 || avgBits > 28 || window < 16 || window > 63 {
            throw ChronicleError.fail("Chunk settings are not usable.")
        }
    }
}

/// 64-bit buzhash. After `window` bytes the state depends only on those
/// bytes, so a later chunk realigns with the previous version.
struct BuzState {
    let table: [UInt64]
    let outTable: [UInt64]
    let window: Int
    private var value: UInt64 = 0
    private var count = 0
    private var ring: [UInt8]
    private var ringAt = 0

    var hash: UInt64 { value }

    init(table: [UInt64] = Gear.table, window: Int = 32) {
        self.table = table
        self.window = window
        self.outTable = table.map { rotl64($0, window) }
        self.ring = [UInt8](repeating: 0, count: window)
    }

    mutating func reset() {
        value = 0
        count = 0
        ringAt = 0
    }

    mutating func feed(_ byte: UInt8) {
        value = rotl64(value, 1) ^ table[Int(byte)]
        if count >= window {
            // The byte that just left the window was rotated once per step.
            value ^= outTable[Int(ring[ringAt])]
        }
        ring[ringAt] = byte
        ringAt += 1
        if ringAt == window { ringAt = 0 }
        count += 1
    }
}

final class ChunkSplitter {
    let params: ChunkParams
    var onChunk: (Data) throws -> Void = { _ in }
    private var hash: BuzState
    /// Bytes since the last cut. A feed copies a tail in one slice, not one byte at a time.
    private var pending = Data()

    init(params: ChunkParams) {
        self.params = params
        self.hash = BuzState(window: params.window)
        pending.reserveCapacity(params.max)
    }

    func feed(_ data: Data) throws {
        if data.isEmpty { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else { return }
            let count = raw.count
            var start = 0
            var length = pending.count
            for index in 0..<count {
                hash.feed(base[index])
                length += 1
                let cut = length >= params.max || (length >= params.min && (hash.hash & params.mask) == 0)
                if cut {
                    try emit(base, start, index)
                    start = index + 1
                    length = 0
                }
            }
            if start < count {
                let tail = Data(bytes: base + start, count: count - start)
                if pending.isEmpty {
                    pending = tail
                } else {
                    pending.append(tail)
                }
            }
        }
    }

    func finish() throws {
        if pending.isEmpty { return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        hash.reset()
        try onChunk(chunk)
    }

    /// Copies `pending` plus `base[start...end]` once. The hash already includes `end`.
    private func emit(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) throws {
        let extra = end - start + 1
        var chunk: Data
        if pending.isEmpty {
            chunk = Data(bytes: base + start, count: extra)
        } else {
            chunk = pending
            chunk.reserveCapacity(chunk.count + extra)
            chunk.append(Data(bytes: base + start, count: extra))
            pending.removeAll(keepingCapacity: true)
        }
        hash.reset()
        try onChunk(chunk)
    }
}

enum Chunker {
    static func split(_ data: Data, params: ChunkParams = .standard) throws -> [Data] {
        try params.validate()
        let parts = ChunkParts()
        let splitter = ChunkSplitter(params: params)
        splitter.onChunk = { parts.items.append($0) }
        try splitter.feed(data)
        try splitter.finish()
        return parts.items
    }
}

private final class ChunkParts {
    var items: [Data] = []
}

enum Digest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isHash(_ text: String) -> Bool {
        guard text.count == 64 else { return false }
        for character in text {
            if !character.isHexDigit { return false }
            if character.isLetter && !character.isLowercase { return false }
        }
        return true
    }
}

enum ChunkCodec {
    static let maxDecoded = 8 * 1024 * 1024
    /// A stored chunk is a 16-byte header plus at most `maxDecoded` raw bytes.
    static var maxFileBytes: Int { 16 + maxDecoded }

    static func encode(_ data: Data) -> Data {
        var method: UInt8 = 0
        var payload = data
        if data.count >= 64, let packed = compress(data), packed.count + 32 < data.count {
            method = 1
            payload = packed
        }
        var out = Data()
        out.reserveCapacity(16 + payload.count)
        out.append(contentsOf: [0x43, 0x4B, 0x30, 0x31])
        out.append(method)
        out.append(contentsOf: [0, 0, 0])
        var size = UInt64(data.count)
        for _ in 0..<8 {
            out.append(UInt8(truncatingIfNeeded: size & 0xFF))
            size >>= 8
        }
        out.append(payload)
        return out
    }

    static func decode(_ raw: Data, max: Int = maxDecoded) throws -> Data {
        guard raw.count >= 16 else { throw ChronicleError.fail("A chunk is too short to read.") }
        guard raw[0] == 0x43, raw[1] == 0x4B, raw[2] == 0x30, raw[3] == 0x31 else {
            throw ChronicleError.fail("A chunk header is not CK01.")
        }
        let method = raw[4]
        var size: UInt64 = 0
        for shift in 0..<8 {
            size |= UInt64(raw[8 + shift]) << (8 * shift)
        }
        if size > UInt64(max) {
            throw ChronicleError.fail("A chunk is larger than Chronicle allows.")
        }
        let payload = raw.subdata(in: 16..<raw.count)
        if method == 0 {
            guard payload.count == Int(size) else {
                throw ChronicleError.fail("A chunk length does not match its header.")
            }
            return payload
        }
        if method == 1 {
            guard let plain = decompress(payload, count: Int(size)) else {
                throw ChronicleError.fail("A chunk did not decompress.")
            }
            return plain
        }
        throw ChronicleError.fail("A chunk uses an encoding Chronicle does not read.")
    }

    private static func compress(_ data: Data) -> Data? {
        let capacity = data.count
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            data.withUnsafeBytes { srcRaw -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstPtr, capacity, srcPtr, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return dst.prefix(written)
    }

    private static func decompress(_ data: Data, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        var dst = Data(count: count)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            data.withUnsafeBytes { srcRaw -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, count, srcPtr, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == count else { return nil }
        return dst
    }
}
