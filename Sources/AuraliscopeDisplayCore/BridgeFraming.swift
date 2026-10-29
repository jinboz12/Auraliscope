import AnalysisCore
import Foundation

/// One framed message: a 16-byte header (magic, type, flags, length, sequence) and its payload (Bridge/PROTOCOL.md,
/// *Framing*). `type` is kept raw: a receiver skips types it does not know.
public struct BridgeMessage: Equatable, Sendable {
    public var type: UInt16
    public var sequence: UInt32
    public var payload: Data

    public init(type: UInt16, sequence: UInt32 = 0, payload: Data = Data()) {
        self.type = type
        self.sequence = sequence
        self.payload = payload
    }

    public var kind: BridgeMessageType? { BridgeMessageType(rawValue: type) }
}

/// Why a byte stream was given up: the connection must close (PROTOCOL.md: a wrong magic or a length above the limit).
public enum BridgeFramingError: Error, Equatable, Sendable {
    case badMagic(UInt32)
    case tooLong(UInt32)
}

/// Cuts a received byte stream into complete messages, whatever the pieces it arrives in (partial headers, partial
/// payloads, several messages at once). It never holds more than one header and one payload of at most
/// `maxPayload` bytes, so a peer cannot make it grow: a declared length above the limit is an error before any of
/// the payload is read. Not thread-safe; one per connection.
public struct BridgeFrameDecoder: Sendable {
    public let maxPayload: Int
    private var buffer = Data()
    private var failure: BridgeFramingError?

    public init(maxPayload: Int = BridgeProtocol.maxPayload) {
        self.maxPayload = min(maxPayload, BridgeProtocol.maxPayload)
    }

    /// Bytes waiting for the rest of their message.
    public var buffered: Int { buffer.count }

    /// Appends received bytes and returns every message they complete, in order. After an error the decoder stays
    /// failed (the caller closes the connection) and returns the same error for any later bytes.
    public mutating func append(_ bytes: Data) throws(BridgeFramingError) -> [BridgeMessage] {
        if let failure { throw failure }
        buffer.append(bytes)
        var messages: [BridgeMessage] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= BridgeProtocol.headerBytes {
            let magic = Self.u32(buffer, offset)
            guard magic == BridgeProtocol.magic else {
                failure = .badMagic(magic)
                buffer.removeAll()
                throw .badMagic(magic)
            }
            let length = Self.u32(buffer, offset + 8)
            guard Int(length) <= maxPayload else {
                failure = .tooLong(length)
                buffer.removeAll()
                throw .tooLong(length)
            }
            let total = BridgeProtocol.headerBytes + Int(length)
            guard buffer.endIndex - offset >= total else { break }
            let type = UInt16(buffer[offset + 4]) | UInt16(buffer[offset + 5]) << 8
            let sequence = Self.u32(buffer, offset + 12)
            let payloadStart = offset + BridgeProtocol.headerBytes
            messages.append(BridgeMessage(type: type, sequence: sequence,
                                          payload: Data(buffer[payloadStart..<(payloadStart + Int(length))])))
            offset += total
        }
        if offset != buffer.startIndex { buffer = Data(buffer[offset...]) }
        return messages
    }

    private static func u32(_ data: Data, _ at: Data.Index) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }
}

/// Frames outgoing messages, numbering them per connection (the header's sequence, for diagnostics).
public struct BridgeFrameEncoder: Sendable {
    public private(set) var sequence: UInt32 = 0

    public init() {}

    public mutating func encode(_ type: BridgeMessageType, _ payload: Data = Data()) -> Data {
        precondition(payload.count <= BridgeProtocol.maxPayload)
        var data = Data(capacity: BridgeProtocol.headerBytes + payload.count)
        Self.append32(&data, BridgeProtocol.magic)
        data.append(UInt8(type.rawValue & 0xFF))
        data.append(UInt8(type.rawValue >> 8))
        data.append(contentsOf: [0, 0])
        Self.append32(&data, UInt32(payload.count))
        Self.append32(&data, sequence)
        sequence &+= 1
        data.append(payload)
        return data
    }

    static func append32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}

/// Builds a field payload (PROTOCOL.md, *Fields*) of at most `capacity` bytes: the control messages a display
/// sends are small. A field that does not fit sets `overflowed` and is left out; the caller then sends nothing.
struct FieldBuilder {
    private var bytes: [UInt8]
    private let capacity: Int
    private(set) var overflowed = false

    init(capacity: Int = 1024, prefix: [UInt8] = []) {
        bytes = prefix
        bytes.reserveCapacity(prefix.count + capacity)
        self.capacity = prefix.count + capacity
    }

    private mutating func field(_ tag: UInt16, _ kind: WireKind, count: Int, _ value: [UInt8]) {
        let padded = (value.count + 3) & ~3
        guard !overflowed, bytes.count + WireLimits.fieldHeader + padded <= capacity else { overflowed = true; return }
        bytes += [UInt8(tag & 0xFF), UInt8(tag >> 8), kind.rawValue, 0]
        bytes += Self.le(UInt32(count))
        bytes += value
        bytes += [UInt8](repeating: 0, count: padded - value.count)
    }

    static func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    static func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    mutating func u32(_ tag: UInt16, _ value: UInt32) { field(tag, .u32, count: 1, Self.le(value)) }
    mutating func u64(_ tag: UInt16, _ value: UInt64) { field(tag, .u64, count: 1, Self.le(value)) }
    mutating func i64(_ tag: UInt16, _ value: Int64) { field(tag, .i64, count: 1, Self.le(UInt64(bitPattern: value))) }
    mutating func f64(_ tag: UInt16, _ value: Double) { field(tag, .f64, count: 1, Self.le(value.bitPattern)) }
    mutating func bytes(_ tag: UInt16, _ value: [UInt8]) { field(tag, .bytes, count: value.count, value) }
    mutating func u8s(_ tag: UInt16, _ value: [UInt8]) { field(tag, .u8, count: value.count, value) }
    /// UTF-8 text, cut at a character boundary to `limit` bytes.
    mutating func text(_ tag: UInt16, _ value: String, limit: Int = WireLimits.text) {
        var utf8 = Array(value.utf8)
        if utf8.count > limit {
            var cut = limit
            while cut > 0 && utf8[cut] & 0xC0 == 0x80 { cut -= 1 }
            utf8 = Array(utf8[..<cut])
        }
        field(tag, .utf8, count: utf8.count, utf8)
    }

    var data: Data { Data(bytes) }
}

/// Reads typed values from one field payload; a missing or mistyped field reads as nil (PROTOCOL.md: a known tag of
/// another kind is ignored as if absent).
struct FieldTable {
    private(set) var u32s: [UInt16: UInt32] = [:]
    private(set) var u64s: [UInt16: UInt64] = [:]
    private(set) var f64s: [UInt16: Double] = [:]
    private(set) var i64s: [UInt16: Int64] = [:]
    private(set) var texts: [UInt16: String] = [:]
    private(set) var blobs: [UInt16: [UInt8]] = [:]
    private(set) var malformed = false

    init(_ payload: Data, blobLimit: Int = 256) {
        payload.withUnsafeBytes { raw in
            var reader = WireReader(raw)
            while let field = reader.next() {
                switch field.kind {
                case .u32: if let v = field.u32 { u32s[field.tag] = v }
                case .u64: if let v = field.u64 { u64s[field.tag] = v }
                case .f64: if let v = field.f64 { f64s[field.tag] = v }
                case .i64:
                    if field.count == 1 { i64s[field.tag] = Int64(littleEndian: field.value.loadUnaligned(as: Int64.self)) }
                case .utf8: if let v = field.text { texts[field.tag] = v }
                case .bytes, .u8: if field.count <= blobLimit { blobs[field.tag] = Array(field.value) }
                case .f32: break
                }
            }
            malformed = reader.malformed
        }
    }

    func id16(_ tag: UInt16) -> [UInt8]? { blobs[tag].flatMap { $0.count == 16 ? $0 : nil } }
}
