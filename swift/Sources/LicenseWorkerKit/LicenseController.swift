import Combine
import Foundation

public enum LicenseStatus: Equatable, Sendable {
    /// No licence, or one that was never confirmed.
    case unlicensed
    case licensed(Basis)
    /// The server sent a SIGNED revocation. Nothing else locks.
    case revoked(reason: String?)
    /// A signed licence with an expiry, past its grace period.
    case expired

    public enum Basis: Equatable, Sendable {
        /// A signed licence that verifies.
        case signed
        /// A signed licence past its expiry, inside the grace period.
        case grace
        /// Open on the previous state: the key of an older app version that
        /// has not been confirmed by the new server yet, or a stored token
        /// this build cannot check.
        case unverified
    }

    public var isUnlocked: Bool {
        if case .licensed = self { return true }
        return false
    }
}

/// What an older version of the app left behind. The app reads it from
/// wherever that version kept it and hands it over; this package never deletes it.
public struct LegacyLicense: Equatable, Sendable {
    public var licenseKey: String
    public var instanceID: String?
    /// Whether the older version considered the app unlocked.
    public var wasUnlocked: Bool

    public init(licenseKey: String, instanceID: String?, wasUnlocked: Bool) {
        self.licenseKey = licenseKey
        self.instanceID = instanceID
        self.wasUnlocked = wasUnlocked
    }
}

public enum LicenseError: Error, Equatable, Sendable {
    case emptyKey
    /// No usable answer: offline, timeout, 429, 5xx or a garbled body.
    case serverUnavailable
    case keyNotFound
    case activationLimitReached
    /// The key is real but belongs to another product (or store).
    case wrongProduct
    /// The server refused the key with a signed revocation.
    case revoked(reason: String?)
    /// The server answered "activated" without a licence this build can verify. The seat was given back.
    case unverifiableAnswer
    /// The licence could not be stored (a locked or unavailable keychain). The seat was given back.
    case storageFailed
    /// Any other refusal, with the server's own words.
    case server(String)
}

/// What one online check did.
public enum RefreshOutcome: Equatable, Sendable {
    case noLicense
    case notDue
    /// The server confirmed the licence with a signed token.
    case confirmed
    /// The server sent a signed revocation: the app is now locked.
    case revoked
    /// The instance was unknown and the app activated itself again.
    case reactivated
    /// Nothing changed, and why.
    case unchanged(Reason)

    public enum Reason: Equatable, Sendable {
        case serverUnavailable
        /// An answer with no signature, whatever it said.
        case unsigned(String?)
        /// A token that did not verify (unknown kid, bad signature, another product...).
        case rejectedToken(TokenRejection)
    }
}

/// The licence state machine. One rule, the same in every app:
///
/// | What happened | What the app does |
/// |---|---|
/// | a valid signed licence is stored | open, whatever the network |
/// | no answer, network error, 5xx, 429, garbled or UNSIGNED answer | stays as it was |
/// | a SIGNED revocation | locks, and shows the reason |
/// | the server does not know the `instance_id` | activates again, silently |
/// | a signed licence past its expiry | validates online; 14 days of grace |
@MainActor
public final class LicenseController: ObservableObject {
    @Published public private(set) var status: LicenseStatus = .unlicensed

    public let configuration: LicenseConfiguration
    private let client: LicenseClient
    private let storage: LicenseStorage
    private let now: @Sendable () -> Date
    private let instanceName: @Sendable () -> String
    private var stored: StoredLicense?
    private var lastAttemptAt: Date?
    private var inFlight: Task<RefreshOutcome, Never>?

    /// - Parameters:
    ///   - legacy: read once, and only while nothing is stored yet: the key an
    ///     older version of the app kept. The app stays open on it until the
    ///     new server confirms it.
    ///   - session: for tests; nil builds an ephemeral session.
    ///   - instanceName: the name an activation is listed under in the admin page (the computer's name).
    public init(
        configuration: LicenseConfiguration,
        storage: LicenseStorage,
        legacy: (() -> LegacyLicense?)? = nil,
        session: URLSession? = nil,
        instanceName: @escaping @Sendable () -> String = { LicenseController.defaultInstanceName() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.storage = storage
        self.client = LicenseClient(baseURL: configuration.baseURL, session: session, timeout: configuration.requestTimeout)
        self.instanceName = instanceName
        self.now = now

        stored = try? storage.load()
        if stored == nil, let old = legacy?() {
            let key = old.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                let imported = StoredLicense(licenseKey: key, instanceID: old.instanceID, unlocked: old.wasUnlocked)
                stored = imported
                try? storage.save(imported)
            }
        }
        status = evaluate()
    }

    /// The computer's name, the default `instanceName`: on a Mac its name as set
    /// in System Settings, elsewhere the host name.
    public nonisolated static func defaultInstanceName() -> String {
        #if os(macOS)
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        #endif
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "device" : host
    }

    public var licenseKey: String? { stored?.licenseKey }
    public var instanceID: String? { stored?.instanceID }
    /// When the server last gave a signed answer about this licence.
    public var lastValidatedAt: Date? { stored?.lastValidatedAt }
    /// True while the stored licence has never been confirmed by a signed token.
    public var isAwaitingFirstConfirmation: Bool { stored != nil && stored?.token == nil }

    // MARK: - Reading the stored state

    private func verdict(of license: StoredLicense) -> TokenVerdict? {
        guard let token = license.token else { return nil }
        return configuration.verifier.verify(
            token,
            expecting: configuration.expectation(licenseKey: license.licenseKey, instanceID: license.instanceID),
            now: now(),
            highWaterMark: license.highWaterMark
        )
    }

    private func evaluate() -> LicenseStatus {
        guard let license = stored else { return .unlicensed }
        switch verdict(of: license) {
        case .valid: return .licensed(.signed)
        case .grace: return .licensed(.grace)
        case .revoked(let payload): return .revoked(reason: payload.reason)
        case .rejected(.expired, _): return .expired
        case .rejected, nil:
            // No token, or one this build cannot check: never a reason to lock.
            return license.unlocked ? .licensed(.unverified) : .unlicensed
        }
    }

    private func persist(_ license: StoredLicense?) {
        stored = license
        if let license {
            try? storage.save(license)
        } else {
            try? storage.clear()
        }
        status = evaluate()
    }

    /// Only a licence with an expiry cares about the clock.
    private func advanceHighWaterMark() {
        guard var license = stored, case .some(let v) = verdict(of: license) else { return }
        let payload: LicenseTokenPayload?
        switch v {
        case .valid(let p), .grace(let p): payload = p
        case .rejected(.expired, let p): payload = p
        default: payload = nil
        }
        guard payload?.expiresAt != nil else { return }
        let current = now()
        if license.highWaterMark.map({ current > $0 }) ?? true {
            license.highWaterMark = current
            stored = license
            try? storage.save(license)
        }
    }

    // MARK: - Online validation

    /// Call at launch and from a timer. Asks the server only when it is due:
    /// at most once per `validationInterval` while a signed licence is in
    /// order, and at every launch while the licence still awaits its first
    /// confirmation, is in grace, or has expired.
    @discardableResult
    public func refreshIfDue() async -> RefreshOutcome {
        guard let license = stored else { return .noLicense }
        let current = now()
        if let last = lastAttemptAt, current >= last, current.timeIntervalSince(last) < configuration.retryInterval {
            return .notDue
        }
        var due = true
        switch verdict(of: license) {
        case .valid, .revoked:
            // In order, or locked by a signed answer: once per interval. A
            // clock set back makes the check due rather than postponing it.
            if let last = license.lastValidatedAt {
                due = current < last || current.timeIntervalSince(last) >= configuration.validationInterval
            }
        default:
            // Awaiting its first confirmation, in grace, expired or unreadable: ask now.
            break
        }
        return due ? await refresh() : .notDue
    }

    /// Asks the server now. Never throws and never locks on anything but a signed revocation.
    @discardableResult
    public func refresh() async -> RefreshOutcome {
        if let running = inFlight { return await running.value }
        let task = Task { await self.performRefresh() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func performRefresh() async -> RefreshOutcome {
        guard let license = stored else { return .noLicense }
        lastAttemptAt = now()
        advanceHighWaterMark()

        // A key without an instance (an older version that never stored one) is activated.
        guard let instanceID = license.instanceID else { return await reactivate(license) }

        switch await client.validate(licenseKey: license.licenseKey, instanceID: instanceID) {
        case .unavailable:
            return .unchanged(.serverUnavailable)
        case .answered(let response, _):
            guard let token = response.token else {
                if ServerErrorText.matches(response.error, ServerErrorText.instanceNotFound) {
                    return await reactivate(license)
                }
                return .unchanged(.unsigned(response.error))
            }
            return apply(token: token, to: license, instanceID: instanceID)
        }
    }

    /// The only place a server answer changes the state: through a token that verifies.
    private func apply(token: String, to license: StoredLicense, instanceID: String) -> RefreshOutcome {
        guard stored?.licenseKey == license.licenseKey else { return .unchanged(.unsigned(nil)) }
        let verdict = configuration.verifier.verify(
            token,
            expecting: configuration.expectation(licenseKey: license.licenseKey, instanceID: instanceID),
            now: now(),
            highWaterMark: license.highWaterMark
        )
        var updated = license
        switch verdict {
        case .valid, .grace:
            updated.instanceID = instanceID
            updated.token = token
            updated.unlocked = true
            updated.lastValidatedAt = now()
            persist(updated)
            return .confirmed
        case .revoked:
            updated.token = token
            updated.unlocked = false
            updated.lastValidatedAt = now()
            persist(updated)
            return .revoked
        case .rejected(let reason, _):
            return .unchanged(.rejectedToken(reason))
        }
    }

    private func reactivate(_ license: StoredLicense) async -> RefreshOutcome {
        switch await client.activate(licenseKey: license.licenseKey, instanceName: instanceName()) {
        case .unavailable:
            return .unchanged(.serverUnavailable)
        case .answered(let response, _):
            guard let token = response.token else { return .unchanged(.unsigned(response.error)) }
            guard response.activated == true, let newInstance = response.instanceID else {
                // A refusal: only a signed revocation may act on it.
                let verdict = configuration.verifier.verify(
                    token,
                    expecting: configuration.expectation(licenseKey: license.licenseKey, instanceID: nil),
                    now: now()
                )
                if case .revoked = verdict {
                    return apply(token: token, to: license, instanceID: license.instanceID ?? "")
                }
                return .unchanged(.unsigned(response.error))
            }
            let outcome = apply(token: token, to: license, instanceID: newInstance)
            switch outcome {
            case .confirmed:
                return .reactivated
            case .unchanged:
                // The seat was taken even though the token could not be
                // checked. Remember it, so the next check validates this
                // instance instead of taking another seat.
                if var current = stored, current.licenseKey == license.licenseKey {
                    current.instanceID = newInstance
                    stored = current
                    try? storage.save(current)
                }
                return outcome
            default:
                return outcome
            }
        }
    }

    // MARK: - What the user does

    /// Activates a key the user typed. On any failure the previous state is untouched.
    public func activate(key input: String) async throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseError.emptyKey }

        let response: LicenseResponse
        switch await client.activate(licenseKey: key, instanceName: instanceName()) {
        case .unavailable: throw LicenseError.serverUnavailable
        case .answered(let r, _): response = r
        }

        guard let token = response.token else {
            if ServerErrorText.matches(response.error, ServerErrorText.keyNotFound) { throw LicenseError.keyNotFound }
            if ServerErrorText.matches(response.error, ServerErrorText.activationLimit) {
                throw LicenseError.activationLimitReached
            }
            if response.activated == true {
                // A seat with nothing this app can keep: give it back.
                if let instanceID = response.instanceID {
                    _ = await client.deactivate(licenseKey: key, instanceID: instanceID)
                }
                throw LicenseError.unverifiableAnswer
            }
            throw LicenseError.server(response.error ?? "The license server refused this key.")
        }

        let verdict = configuration.verifier.verify(
            token,
            expecting: configuration.expectation(licenseKey: key, instanceID: response.instanceID),
            now: now()
        )
        switch verdict {
        case .valid, .grace:
            guard response.activated == true, let instanceID = response.instanceID else {
                throw LicenseError.server(response.error ?? "The license server refused this key.")
            }
            let license = StoredLicense(
                licenseKey: key, instanceID: instanceID, token: token, unlocked: true, lastValidatedAt: now()
            )
            do {
                try storage.save(license)
            } catch {
                // A licence that cannot be kept would be lost at the next launch, with its seat.
                _ = await client.deactivate(licenseKey: key, instanceID: instanceID)
                throw LicenseError.storageFailed
            }
            stored = license
            status = evaluate()
        case .revoked(let payload):
            // A signed revocation of the key the app is running on locks it too.
            if let current = stored, LicenseKeyHash.hash(current.licenseKey) == payload.keyHash {
                var updated = current
                updated.token = token
                updated.unlocked = false
                updated.lastValidatedAt = now()
                persist(updated)
            }
            throw LicenseError.revoked(reason: payload.reason)
        case .rejected(let reason, _):
            // The server gave this Mac a seat for a key this app cannot use: give it back.
            if response.activated == true, let instanceID = response.instanceID {
                _ = await client.deactivate(licenseKey: key, instanceID: instanceID)
            }
            throw reason == .wrongProduct ? LicenseError.wrongProduct : LicenseError.unverifiableAnswer
        }
    }

    /// Gives this Mac's seat back and forgets the licence. If the server cannot
    /// be reached the licence is kept, so the seat is not left taken behind a
    /// Mac that no longer knows it.
    public func deactivate() async throws {
        guard let license = stored else { return }
        if let instanceID = license.instanceID {
            if case .unavailable = await client.deactivate(licenseKey: license.licenseKey, instanceID: instanceID) {
                throw LicenseError.serverUnavailable
            }
        }
        persist(nil)
    }
}
