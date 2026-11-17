import Foundation
import Security

/// Everything the client remembers between launches.
public struct StoredLicense: Codable, Equatable, Sendable {
    public var licenseKey: String
    public var instanceID: String?
    /// The last signed token the server sent that verified: a licence or a revocation.
    public var token: String?
    /// The state the app was in when it last knew: this is "the previous
    /// state" an unusable answer leaves untouched. It also carries an upgrade
    /// from a version that had no signed licence yet.
    public var unlocked: Bool
    /// When the server last gave a signed answer.
    public var lastValidatedAt: Date?
    /// The latest time ever observed, against a clock set back.
    public var highWaterMark: Date?

    public init(
        licenseKey: String,
        instanceID: String? = nil,
        token: String? = nil,
        unlocked: Bool = false,
        lastValidatedAt: Date? = nil,
        highWaterMark: Date? = nil
    ) {
        self.licenseKey = licenseKey
        self.instanceID = instanceID
        self.token = token
        self.unlocked = unlocked
        self.lastValidatedAt = lastValidatedAt
        self.highWaterMark = highWaterMark
    }
}

public protocol LicenseStorage: Sendable {
    func load() throws -> StoredLicense?
    func save(_ license: StoredLicense) throws
    func clear() throws
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// One generic-password item holding the licence as JSON, so the key, the
/// instance id and the token are always written together.
public struct KeychainLicenseStorage: LicenseStorage {
    public let service: String
    public let account: String

    /// - Parameter service: unique per app, e.g. `"<bundle id>.license"`.
    public init(service: String, account: String = "license") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> StoredLicense? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        // An item this version cannot read is treated as absent rather than as an error.
        return try? Self.decoder.decode(StoredLicense.self, from: data)
    }

    public func save(_ license: StoredLicense) throws {
        let data = try Self.encoder.encode(license)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let add = SecItemAdd(q as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// A JSON file: for command-line tools, tests, or an app that keeps its
/// licence in its own container. Prefer `KeychainLicenseStorage` in an app.
public struct FileLicenseStorage: LicenseStorage {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> StoredLicense? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A file this version cannot read is treated as absent rather than as an error.
        return try? Self.decoder.decode(StoredLicense.self, from: data)
    }

    public func save(_ license: StoredLicense) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(license).write(to: url, options: .atomic)
    }

    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// For tests and previews.
public final class InMemoryLicenseStorage: LicenseStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredLicense?
    /// Set to make every write fail, as a locked keychain would.
    public var failWrites = false

    public init(_ initial: StoredLicense? = nil) { value = initial }

    public func load() throws -> StoredLicense? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ license: StoredLicense) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw KeychainError(status: errSecInteractionNotAllowed) }
        value = license
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw KeychainError(status: errSecInteractionNotAllowed) }
        value = nil
    }
}
