public import LimbCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Protects `requestState`, the opaque blob a client echoes back between the rounds of a
/// multi round-trip request.
///
/// `open` runs in the request's task before its handler, `seal` after it; both hold the
/// request's handler slot while they run.
///
/// The state passes through the client, so the specification requires treating it as
/// attacker-controlled: it must be integrity-protected and rejected when verification fails.
public protocol RequestStateSealer: Sendable {
    func seal(_ plaintext: [UInt8]) throws -> String
    func open(_ sealed: String) throws -> [UInt8]
}

public struct RequestStateError: Error, Sendable, CustomStringConvertible {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// ChaCha20-Poly1305 with a fresh subkey per state.
///
/// Each state is sealed under a key derived by HKDF from the master key and a random salt, so
/// the random 96-bit nonce cannot wear out even under a long-lived key shared by many servers.
/// The key identifier and format version are authenticated but not encrypted, which is what
/// lets a server holding several keys pick the right one during rotation.
public struct AEADRequestStateSealer: RequestStateSealer {
    private let currentID: String
    private let keys: [String: SymmetricKey]

    /// - Parameters:
    ///   - key: 32 bytes of key material.
    ///   - keyID: a short public name for the key.
    ///   - previous: keys that are no longer used for sealing but still accepted, for rotation.
    public init(key: [UInt8], keyID: String = "k1", previous: [String: [UInt8]] = [:]) {
        precondition(key.count >= 32, "request state key must be at least 32 bytes")
        // The identifier's length is written into the state as one byte.
        precondition(keyID.utf8.count <= 255, "request state key id must be at most 255 bytes")
        // An old key opens states as the current one seals them: the same rules apply.
        for (id, material) in previous {
            precondition(material.count >= 32, "request state key \"\(id)\" must be at least 32 bytes")
            precondition(id.utf8.count <= 255, "request state key id must be at most 255 bytes")
        }
        var keys = previous.mapValues { SymmetricKey(data: $0) }
        keys[keyID] = SymmetricKey(data: key)
        self.keys = keys
        currentID = keyID
    }

    /// A random key that lives as long as the process. Right for stdio, where the process that
    /// sealed a state is the only one that can receive it back.
    public static func ephemeral() -> AEADRequestStateSealer {
        let key = SymmetricKey(size: .bits256)
        return AEADRequestStateSealer(key: key.withUnsafeBytes { Array($0) }, keyID: "p")
    }

    private static let version: UInt8 = 1
    private static let saltSize = 16

    public func seal(_ plaintext: [UInt8]) throws -> String {
        guard let master = keys[currentID] else { throw RequestStateError(reason: "no sealing key") }
        let identifier = Array(currentID.utf8)
        var salt = [UInt8](repeating: 0, count: Self.saltSize)
        for index in salt.indices { salt[index] = UInt8.random(in: 0...255) }
        let header = [Self.version, UInt8(identifier.count)] + identifier
        let subkey = Self.subkey(master, salt: salt)
        let box = try ChaChaPoly.seal(plaintext, using: subkey, authenticating: header)
        return Base64.encode(header + salt + Array(box.combined), urlSafe: true)
    }

    public func open(_ sealed: String) throws -> [UInt8] {
        guard let bytes = Base64.decode(sealed), bytes.count > 2, bytes[0] == Self.version else {
            throw RequestStateError(reason: "unrecognized format")
        }
        let identifierLength = Int(bytes[1])
        let headerLength = 2 + identifierLength
        guard bytes.count > headerLength + Self.saltSize else { throw RequestStateError(reason: "truncated") }
        let header = Array(bytes[..<headerLength])
        let identifier = String(decoding: bytes[2..<headerLength], as: UTF8.self)
        guard let master = keys[identifier] else { throw RequestStateError(reason: "unknown key") }
        let salt = Array(bytes[headerLength..<headerLength + Self.saltSize])
        do {
            let box = try ChaChaPoly.SealedBox(combined: bytes[(headerLength + Self.saltSize)...])
            return Array(try ChaChaPoly.open(box, using: Self.subkey(master, salt: salt), authenticating: header))
        } catch {
            throw RequestStateError(reason: "failed verification")
        }
    }

    private static func subkey(_ master: SymmetricKey, salt: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: salt, info: Array("limb/request-state/v1".utf8), outputByteCount: 32)
    }
}

/// What a sealed `requestState` carries between rounds.
struct RequestStatePayload {
    enum Version: Int {
        case legacy = 1
        case exact = 2
        case principalBound = 3
    }

    var version: Version
    /// Unix time at which the state expires.
    var expires: Int
    /// Identifies the request the state was issued for, so it cannot be replayed on another one.
    var fingerprint: String
    /// Answers gathered in earlier rounds, by input key. The client returns only the current
    /// round's answers, so earlier ones travel here.
    var journal: JSONObject

    func encoded() -> [UInt8] {
        var writer = JSONWriter()
        writer.beginObject()
        writer.field("v", version.rawValue)
        writer.field("exp", expires)
        writer.field("fp", fingerprint)
        writer.field("j", journal)
        writer.endObject()
        return writer.bytes
    }

    init(expires: Int, fingerprint: String, journal: JSONObject, version: Version = .exact) {
        self.version = version
        self.expires = expires
        self.fingerprint = fingerprint
        self.journal = journal
    }

    init?(_ bytes: [UInt8]) {
        guard let value = try? JSON.parse(bytes), let rawVersion = value["v"]?.intValue,
            let version = Version(rawValue: rawVersion),
            let expires = value["exp"]?.intValue, let fingerprint = value["fp"]?.stringValue,
            let journal = value["j"]?.objectValue
        else { return nil }
        self.init(expires: expires, fingerprint: fingerprint, journal: journal, version: version)
    }
}

/// A digest of what identifies a request across its rounds: the method, the thing addressed and
/// its arguments. `_meta` is excluded on purpose: progress tokens and trace context legitimately
/// change between rounds.
func requestFingerprint(
    method: String, target: String, arguments: JSONValue, version: RequestStatePayload.Version = .exact,
    principal: String? = nil
) -> String {
    var writer = JSONWriter()
    writer.beginArray()
    writer.write(method)
    writer.write(target)
    writeCanonical(arguments, to: &writer, version: version)
    if version == .principalBound { writer.write(principal.map(JSONValue.string) ?? .null) }
    writer.endArray()
    let digest = SHA256.hash(data: writer.bytes)
    return Base64.encode(Array(digest), urlSafe: true)
}

/// Object members in sorted order, so equal values hash equally however the client ordered them.
private func writeCanonical(_ value: JSONValue, to writer: inout JSONWriter, version: RequestStatePayload.Version) {
    switch value {
    case .object(let object):
        writer.beginObject()
        let fields = object.sorted {
            switch version {
            case .legacy: $0.key < $1.key
            case .exact, .principalBound: $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
            }
        }
        for (key, member) in fields {
            writer.key(key)
            writeCanonical(member, to: &writer, version: version)
        }
        writer.endObject()
    case .array(let array):
        writer.beginArray()
        for element in array { writeCanonical(element, to: &writer, version: version) }
        writer.endArray()
    case .number(let number) where version != .legacy:
        writer.write(number.canonicalDecimal)
    default:
        writer.write(value)
    }
}
