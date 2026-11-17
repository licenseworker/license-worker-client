import CryptoKit
import Foundation

/// The signed licence.
///
///     token     = "v1." + b64url(payload JSON) + "." + b64url(signature)
///     signature = Ed25519 over the ASCII bytes of "v1." + b64url(payload JSON)
///
/// The format and the verification steps are in PROTOCOL.md. This verifier
/// must reach the same verdict, with the same reason, on every case of
/// `tests/vectors/license-token-v1.json`, like the Rust one.
public struct LicenseTokenPayload: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Unlocks.
        case license
        /// The only thing that locks an app.
        case revoked
    }

    public let version: Int
    public let kid: String
    public let kind: Kind
    /// sha256 hex of the licence key, whitespace removed and lowercased.
    public let keyHash: String
    public let storeID: Int
    public let productID: Int
    public let variantID: Int
    /// nil when the key was validated without an instance.
    public let instanceID: String?
    /// Issued at, unix seconds.
    public let issuedAt: Int
    /// Expiry, unix seconds. nil = perpetual.
    public let expiresAt: Int?
    /// `disabled`, `refunded` or `expired`; only on a revocation.
    public let reason: String?
}

public enum TokenRejection: String, Equatable, Sendable {
    case malformed
    case unsupportedVersion = "unsupported_version"
    case unknownKid = "unknown_kid"
    case badSignature = "bad_signature"
    case wrongKey = "wrong_key"
    case wrongProduct = "wrong_product"
    case wrongInstance = "wrong_instance"
    case expired
}

public enum TokenVerdict: Equatable, Sendable {
    case valid(LicenseTokenPayload)
    /// Past `exp`, inside the grace period: still opens the app.
    case grace(LicenseTokenPayload)
    case revoked(LicenseTokenPayload)
    /// The payload is present only when the signature held.
    case rejected(TokenRejection, LicenseTokenPayload?)
}

/// What the token must be about. A nil field is not checked.
public struct TokenExpectation: Equatable, Sendable {
    public var keyHash: String?
    public var storeID: Int?
    public var productIDs: [Int]?
    public var variantIDs: [Int]?
    public var instanceID: String?

    public init(
        keyHash: String? = nil,
        storeID: Int? = nil,
        productIDs: [Int]? = nil,
        variantIDs: [Int]? = nil,
        instanceID: String? = nil
    ) {
        self.keyHash = keyHash
        self.storeID = storeID
        self.productIDs = productIDs
        self.variantIDs = variantIDs
        self.instanceID = instanceID
    }
}

public struct LicenseTokenVerifier: Sendable {
    public static let defaultGraceSeconds: TimeInterval = 14 * 24 * 3600

    /// kid -> raw 32-byte Ed25519 public key, base64. An app embeds two:
    /// the active key and the backup, so the server can rotate without a release.
    public let publicKeys: [String: String]
    public let graceSeconds: TimeInterval

    public init(publicKeys: [String: String], graceSeconds: TimeInterval = LicenseTokenVerifier.defaultGraceSeconds) {
        self.publicKeys = publicKeys
        self.graceSeconds = graceSeconds
    }

    /// - Parameter highWaterMark: the latest time this client has ever observed.
    ///   Setting the clock back cannot stretch an expired licence past it. A
    ///   perpetual licence ignores the clock entirely.
    public func verify(
        _ token: String,
        expecting expect: TokenExpectation = TokenExpectation(),
        now: Date,
        highWaterMark: Date? = nil
    ) -> TokenVerdict {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .rejected(.malformed, nil) }
        let (prefix, body, signaturePart) = (parts[0], parts[1], parts[2])
        guard prefix == "v1" else { return .rejected(.unsupportedVersion, nil) }

        guard
            let bodyData = Base64URL.decode(body),
            let object = try? JSONSerialization.jsonObject(with: bodyData),
            let payload = Self.parsePayload(object),
            let signature = Base64URL.decode(signaturePart)
        else { return .rejected(.malformed, nil) }

        guard payload.version == 1 else { return .rejected(.unsupportedVersion, nil) }
        guard signature.count == 64 else { return .rejected(.badSignature, nil) }

        // Nothing in the payload is trusted before the signature holds; `kid`
        // only picks which embedded key to try.
        guard let publicKeyB64 = publicKeys[payload.kid] else { return .rejected(.unknownKid, nil) }
        guard
            let raw = Data(base64Encoded: publicKeyB64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
            key.isValidSignature(signature, for: Data("\(prefix).\(body)".utf8))
        else { return .rejected(.badSignature, nil) }

        if let hash = expect.keyHash, hash != payload.keyHash { return .rejected(.wrongKey, payload) }
        if let store = expect.storeID, store != payload.storeID { return .rejected(.wrongProduct, payload) }
        if let products = expect.productIDs, !products.contains(payload.productID) {
            return .rejected(.wrongProduct, payload)
        }
        if let variants = expect.variantIDs, !variants.contains(payload.variantID) {
            return .rejected(.wrongProduct, payload)
        }

        // A revocation is about the key, whichever instance asked.
        if payload.kind == .revoked { return .revoked(payload) }

        if let instance = expect.instanceID, instance != payload.instanceID {
            return .rejected(.wrongInstance, payload)
        }

        guard let exp = payload.expiresAt else { return .valid(payload) }

        var nowSeconds = Int(now.timeIntervalSince1970.rounded(.down))
        if let mark = highWaterMark {
            nowSeconds = max(nowSeconds, Int(mark.timeIntervalSince1970.rounded(.down)))
        }
        if nowSeconds <= exp { return .valid(payload) }
        if nowSeconds <= exp + Int(graceSeconds) { return .grace(payload) }
        return .rejected(.expired, payload)
    }

    /// Mirrors `isPayload` of the reference: every field present and of its type.
    private static func parsePayload(_ object: Any) -> LicenseTokenPayload? {
        guard let p = object as? [String: Any] else { return nil }
        guard
            let version = integer(p["v"]),
            let kid = p["kid"] as? String,
            let typ = p["typ"] as? String, let kind = LicenseTokenPayload.Kind(rawValue: typ),
            let keyHash = p["key_hash"] as? String,
            let storeID = integer(p["store_id"]),
            let productID = integer(p["product_id"]),
            let variantID = integer(p["variant_id"]),
            let issuedAt = integer(p["iat"])
        else { return nil }

        let instanceID: String?
        switch p["instance_id"] {
        case is NSNull: instanceID = nil
        case let s as String: instanceID = s
        default: return nil
        }

        let expiresAt: Int?
        switch p["exp"] {
        case is NSNull: expiresAt = nil
        case let value?:
            guard let n = integer(value) else { return nil }
            expiresAt = n
        default: return nil
        }

        return LicenseTokenPayload(
            version: version, kid: kid, kind: kind, keyHash: keyHash, storeID: storeID,
            productID: productID, variantID: variantID, instanceID: instanceID,
            issuedAt: issuedAt, expiresAt: expiresAt, reason: p["reason"] as? String
        )
    }

    /// A JSON number that is an integer. `true` and `false` are not numbers.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9e15 else { return nil }
        return number.intValue
    }
}

public enum LicenseKeyHash {
    /// sha256 hex of the licence key with all whitespace removed and lowercased.
    public static func hash(_ licenseKey: String) -> String {
        let normalized = String(licenseKey.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            .lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum Base64URL {
    /// Unpadded base64url, as the server writes it. Anything else is nil.
    static func decode(_ text: String) -> Data? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
