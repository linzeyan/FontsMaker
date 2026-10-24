/// Big-endian cursor over a byte array.
///
/// Input fonts are untrusted files, so every read is bounds-checked against
/// `end` and throws instead of trapping.
struct ByteReader {
    let bytes: [UInt8]
    let end: Int
    var offset: Int
    /// Table tag (or other label) used in error messages.
    let context: String

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil, context: String) {
        self.bytes = bytes
        self.offset = start
        self.end = min(end ?? bytes.count, bytes.count)
        self.context = context
    }

    private func require(_ count: Int) throws {
        guard count >= 0, offset >= 0, offset + count <= end else {
            throw FontLoadError.malformed("\(context): unexpected end of data at offset \(offset)")
        }
    }

    mutating func seek(_ position: Int) throws {
        guard position >= 0, position <= end else {
            throw FontLoadError.malformed("\(context): offset \(position) out of bounds")
        }
        offset = position
    }

    mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func i8() throws -> Int8 {
        Int8(bitPattern: try u8())
    }

    mutating func u16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func i16() throws -> Int16 {
        Int16(bitPattern: try u16())
    }

    mutating func u32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func i64() throws -> Int64 {
        let high = UInt64(try u32())
        let low = UInt64(try u32())
        return Int64(bitPattern: high << 32 | low)
    }

    mutating func tag() throws -> String {
        String(decoding: try read(4), as: UTF8.self)
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        try require(count)
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// Big-endian byte sink used by every table serializer.
struct ByteWriter {
    var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func i8(_ value: Int8) { bytes.append(UInt8(bitPattern: value)) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }

    mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }

    mutating func padToFourBytes() {
        while bytes.count % 4 != 0 { bytes.append(0) }
    }
}

extension Array where Element == UInt8 {
    func readU16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readI16(at offset: Int) -> Int16 {
        Int16(bitPattern: readU16(at: offset))
    }

    mutating func writeU16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value >> 8)
        self[offset + 1] = UInt8(value & 0xFF)
    }

    mutating func writeI16(_ value: Int16, at offset: Int) {
        writeU16(UInt16(bitPattern: value), at: offset)
    }

    mutating func writeU32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value >> 24)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}

/// OpenType table checksum: the wrapping sum of big-endian UInt32 words,
/// with the final partial word zero-padded.
func tableChecksum(_ bytes: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    var index = 0
    let fullWords = bytes.count / 4 * 4
    while index < fullWords {
        let word =
            UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
        sum = sum &+ word
        index += 4
    }
    if index < bytes.count {
        var word: UInt32 = 0
        for shift in 0..<4 {
            let byte = index + shift < bytes.count ? UInt32(bytes[index + shift]) : 0
            word |= byte << (24 - 8 * UInt32(shift))
        }
        sum = sum &+ word
    }
    return sum
}

/// Tags compare by raw bytes in the table directory (uppercase sorts before lowercase).
func tagPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
}
