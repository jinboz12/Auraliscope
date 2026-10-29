import CommonCrypto
import Foundation
import Security

/// Network pairing between a Mac running Auraliscope Bridge and an Auraliscope display (BRIDGE_NETWORK.md).
///
/// Every network connection is TLS 1.2 with a pre-shared key (Network.framework, TLS_PSK_WITH_AES_128_GCM_SHA256):
/// nothing crosses the network in the clear, and only a peer holding the key completes the handshake.
///
/// - **Pairing** happens once per Mac. The display shows an 8-character code (40 bits) and opens a pairing listener.
///   The plugin derives the pairing key from the code (PBKDF2-HMAC-SHA256, 200,000 iterations, salted with the
///   display's receiver ID) and connects; a wrong code fails the handshake. The display asks its user to allow the
///   Mac, then sends a fresh random 256-bit key over that encrypted channel. The pairing listener accepts one Mac,
///   closes after five failed handshakes, and closes after three minutes.
/// - **Display connections** use the paired key, with the Mac's device ID as the PSK identity. The display holds one
///   key per paired Mac and can forget any of them.
public enum BridgePairing {
    public static let codeLength = 8
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")   // Crockford base32: no I, L, O, U
    public static let iterations: UInt32 = 200_000
    public static let saltPrefix = Array("AuraliscopeBridgePair1".utf8)
    public static let pairingIdentity = Array("pair".utf8)
    public static let keyBytes = 32
    public static let pairingWindow: TimeInterval = 180
    public static let maxFailedHandshakes = 5

    /// A new random code, as typed: 8 characters of the Crockford alphabet.
    public static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return String(bytes.map { alphabet[Int($0) & 31] })
    }

    /// "ABCD-EFGH" for showing.
    public static func formatted(_ code: String) -> String {
        code.count == codeLength ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }

    /// What a person typed, as the code: case, spaces and dashes ignored, O read as 0 and I, L as 1. nil when it is not
    /// 8 characters of the alphabet.
    public static func normalise(_ typed: String) -> String? {
        var out = ""
        for c in typed.uppercased() {
            if c == "-" || c == " " { continue }
            let mapped: Character = c == "O" ? "0" : (c == "I" || c == "L") ? "1" : c
            guard alphabet.contains(mapped) else { return nil }
            out.append(mapped)
        }
        return out.count == codeLength ? out : nil
    }

    /// The pairing key for `code` at the display `receiverID` (16 bytes).
    public static func pairingKey(code: String, receiverID: [UInt8]) -> [UInt8]? {
        guard let code = normalise(code), receiverID.count == 16 else { return nil }
        let password = Array(code.utf8)
        let salt = saltPrefix + receiverID
        var key = [UInt8](repeating: 0, count: keyBytes)
        let status = password.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: CChar.self),
                                 p.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                 &key, key.count)
        }
        return status == kCCSuccess ? key : nil
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return bytes
    }

    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    public static func bytes(hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// The pairing exchange itself, over the pairing connection (after its TLS handshake succeeded).
public enum BridgePairingMessages {
    public struct Request: Equatable, Sendable {
        public var deviceID: [UInt8]
        public var computerName: String
        public var hostName: String
        public var pluginVersion: String

        public init(deviceID: [UInt8], computerName: String, hostName: String, pluginVersion: String) {
            self.deviceID = deviceID
            self.computerName = computerName
            self.hostName = hostName
            self.pluginVersion = pluginVersion
        }

        public static func parse(_ payload: Data) -> Request? {
            let f = FieldTable(payload)
            guard let id = f.id16(PairTag.deviceID) else { return nil }
            return Request(deviceID: id, computerName: BridgeHello.clean(f.texts[PairTag.computerName], 63),
                           hostName: BridgeHello.clean(f.texts[PairTag.hostName], 63),
                           pluginVersion: BridgeHello.clean(f.texts[PairTag.pluginVersion], 31))
        }

        public func encoded() -> Data {
            var b = FieldBuilder(capacity: 256)
            b.bytes(PairTag.deviceID, deviceID)
            b.text(PairTag.computerName, computerName, limit: 63)
            b.text(PairTag.hostName, hostName, limit: 63)
            b.text(PairTag.pluginVersion, pluginVersion, limit: 31)
            return b.data
        }
    }

    public static func grant(receiverID: [UInt8], receiverName: String, key: [UInt8]) -> Data {
        var b = FieldBuilder(capacity: 256)
        b.bytes(PairTag.receiverID, receiverID)
        b.text(PairTag.receiverName, receiverName, limit: 63)
        b.bytes(PairTag.key, key)
        return b.data
    }

    public static func deny(_ reason: String) -> Data {
        var b = FieldBuilder(capacity: 160)
        b.text(PairTag.reason, reason, limit: 127)
        return b.data
    }

    public struct Grant: Equatable, Sendable {
        public var receiverID: [UInt8]
        public var receiverName: String
        public var key: [UInt8]

        public init(receiverID: [UInt8], receiverName: String, key: [UInt8]) {
            self.receiverID = receiverID
            self.receiverName = receiverName
            self.key = key
        }

        public static func parse(_ payload: Data) -> Grant? {
            let f = FieldTable(payload)
            guard let id = f.id16(PairTag.receiverID), let key = f.blobs[PairTag.key], key.count == BridgePairing.keyBytes
            else { return nil }
            return Grant(receiverID: id, receiverName: BridgeHello.clean(f.texts[PairTag.receiverName], 63), key: key)
        }
    }
}

/// TXT record of a receiver's DNS-SD advertisement (BridgeDiscovery.h). `proto` and `schema` are the actual protocol
/// constants, never typed in by hand.
public enum BridgeServiceTXT {
    public static func record(receiverID: [UInt8], version: String, pairingPort: UInt16?) -> [String: String] {
        var txt = ["proto": String(BridgeProtocol.version), "schema": String(BridgeProtocol.analysisSchema),
                   "platform": "iPadOS", "app": "Auraliscope", "ver": version, "role": "display",
                   "transport": "tls-psk", "rid": BridgePairing.hex(receiverID)]
        if let pairingPort { txt["pair"] = String(pairingPort) }
        return txt
    }
}
