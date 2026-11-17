import XCTest
@testable import LicenseWorkerKit
import LicenseWorkerKitTesting

private let key = "38b1460a-5104-4067-a91d-77b872934d51"
private let otherKey = "11111111-2222-4333-8444-555555555555"
private let instance = "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17"
private let newInstance = "99999999-aaaa-4bbb-8ccc-dddddddddddd"
private let appProduct = 4100105
private let day: TimeInterval = 24 * 3600

/// The states an app can be in before an online check.
private enum Start: String, CaseIterable {
    /// A stored signed licence that verifies.
    case signed
    /// The key of an older version, open, never confirmed by the new server.
    case legacyOpen
    /// A key with no signed licence, and the app locked.
    case keyButLocked
    /// Locked by a signed revocation.
    case revoked

    var stored: StoredLicense {
        switch self {
        case .signed:
            return StoredLicense(
                licenseKey: key, instanceID: instance,
                token: TestKeys.token(key: key, instanceID: instance), unlocked: true
            )
        case .legacyOpen: return StoredLicense(licenseKey: key, instanceID: instance, unlocked: true)
        case .keyButLocked: return StoredLicense(licenseKey: key, instanceID: instance, unlocked: false)
        case .revoked:
            return StoredLicense(
                licenseKey: key, instanceID: instance,
                token: TestKeys.token(typ: "revoked", key: key, instanceID: instance, reason: "refunded"),
                unlocked: false
            )
        }
    }

    var status: LicenseStatus {
        switch self {
        case .signed: return .licensed(.signed)
        case .legacyOpen: return .licensed(.unverified)
        case .keyButLocked: return .unlicensed
        case .revoked: return .revoked(reason: "refunded")
        }
    }
}

@MainActor
private final class Rig {
    let server = FakeServer()
    let storage: InMemoryLicenseStorage
    let clock = TestClock()
    let controller: LicenseController

    init(_ stored: StoredLicense?, legacy: LegacyLicense? = nil) {
        storage = InMemoryLicenseStorage(stored)
        let clock = self.clock
        controller = LicenseController(
            configuration: LicenseConfiguration(
                baseURL: server.baseURL, publicKeys: TestKeys.trusted,
                storeID: 100200, productIDs: [appProduct]
            ),
            storage: storage,
            legacy: { legacy },
            session: server.session,
            instanceName: { "Test Mac" },
            now: { clock.now }
        )
    }

    var saved: StoredLicense? { try? storage.load() }
}

private func validBody(token: String?, instanceID: String = instance) -> [String: Any?] {
    [
        "valid": true, "error": nil,
        "license_key": ["id": 1, "status": "active", "key": key, "activation_limit": 3, "activation_usage": 1],
        "instance": ["id": instanceID, "name": "Test Mac"],
        "meta": ["store_id": 100200, "product_id": appProduct, "variant_id": 5100105],
        "token": token,
    ]
}

private func activatedBody(token: String?, instanceID: String = newInstance, product: Int = appProduct) -> [String: Any?] {
    [
        "activated": true, "error": nil,
        "license_key": ["id": 1, "status": "active", "key": key, "activation_limit": 3, "activation_usage": 1],
        "instance": ["id": instanceID, "name": "Test Mac"],
        "meta": ["store_id": 100200, "product_id": product, "variant_id": 5100105],
        "token": token,
    ]
}

private func revokedBody(flag: String = "valid", token: String?, error: String = "This license key is disabled.") -> [String: Any?] {
    [
        flag: false, "error": error,
        "license_key": ["id": 1, "status": "disabled", "key": key, "activation_limit": 3, "activation_usage": 1],
        "instance": nil,
        "meta": ["store_id": 100200, "product_id": appProduct, "variant_id": 5100105],
        "token": token,
    ]
}

/// Every row of the controller's decision table (see `LicenseController`),
/// from every state the app can be in.
@MainActor
final class StateMachineTests: XCTestCase {
    // MARK: Row 1: a valid signed licence opens the app, whatever the network

    func testAStoredSignedLicenceOpensTheAppWithoutAnyRequest() {
        let rig = Rig(Start.signed.stored)
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
        XCTAssertTrue(rig.controller.status.isUnlocked)
        XCTAssertEqual(rig.server.calls.count, 0)
    }

    func testEveryStartingStateReadsBackAsItself() {
        for start in Start.allCases {
            XCTAssertEqual(Rig(start.stored).controller.status, start.status, start.rawValue)
        }
        XCTAssertEqual(Rig(nil).controller.status, .unlicensed)
    }

    // MARK: Row 2: no usable answer leaves the app exactly as it was

    /// Every answer that must change nothing, against every starting state.
    func testAnswersThatChangeNothing() async {
        let unknownKid = TestKeys.token(kid: "k-test-9", key: key, instanceID: instance)
        let unknownKidRevoked = TestKeys.token(kid: "k-test-9", typ: "revoked", key: key, instanceID: instance, reason: "disabled")
        let forgedRevoked = TestKeys.token(
            kid: "k-test-1", signWith: "k-test-9", typ: "revoked", key: key, instanceID: instance, reason: "disabled"
        )
        let revokedOtherKey = TestKeys.token(typ: "revoked", key: otherKey, instanceID: instance, reason: "disabled")
        let otherProduct = TestKeys.token(key: key, productID: 4100106, instanceID: instance)
        let otherStore = TestKeys.token(key: key, storeID: 1, instanceID: instance)
        let otherInstance = TestKeys.token(key: key, instanceID: newInstance)

        let rows: [(String, StubProtocol.Reply, RefreshOutcome)] = [
            ("network error", .offline, .unchanged(.serverUnavailable)),
            ("timeout", StubProtocol.Reply(error: URLError(.timedOut)), .unchanged(.serverUnavailable)),
            ("500", .json(["valid": false, "error": "boom"], status: 500), .unchanged(.serverUnavailable)),
            ("503", .json(["valid": false, "error": "The license service is temporarily unavailable. Please try again."], status: 503), .unchanged(.serverUnavailable)),
            ("429", .json(["valid": false, "error": "Too many requests. Please try again later."], status: 429), .unchanged(.serverUnavailable)),
            ("garbled html", .raw("<html>Sign in to Wi-Fi</html>"), .unchanged(.serverUnavailable)),
            ("garbled json", .raw("{\"valid\": fal"), .unchanged(.serverUnavailable)),
            ("unsigned: key not found", .json(["valid": false, "error": "license_key not found."], status: 404),
             .unchanged(.unsigned("license_key not found."))),
            ("unsigned: disabled, no token", .json(revokedBody(token: nil), status: 400),
             .unchanged(.unsigned("This license key is disabled."))),
            ("unsigned: valid=false on 200", .json(["valid": false, "error": nil]), .unchanged(.unsigned(nil))),
            ("unsigned: valid=true, no token", .json(validBody(token: nil)), .unchanged(.unsigned(nil))),
            ("unsigned: 422", .json(["message": "The license key field is required.", "errors": [:] as [String: Any]], status: 422),
             .unchanged(.unsigned("The license key field is required."))),
            ("licence signed by an unknown kid", .json(validBody(token: unknownKid)), .unchanged(.rejectedToken(.unknownKid))),
            ("revocation signed by an unknown kid", .json(revokedBody(token: unknownKidRevoked), status: 400),
             .unchanged(.rejectedToken(.unknownKid))),
            ("revocation with a forged signature", .json(revokedBody(token: forgedRevoked), status: 400),
             .unchanged(.rejectedToken(.badSignature))),
            ("revocation of another key", .json(revokedBody(token: revokedOtherKey), status: 400),
             .unchanged(.rejectedToken(.wrongKey))),
            ("token that is not a token", .json(validBody(token: "v1.not-a-token")), .unchanged(.rejectedToken(.malformed))),
            ("licence of another product", .json(validBody(token: otherProduct)), .unchanged(.rejectedToken(.wrongProduct))),
            ("licence of another store", .json(validBody(token: otherStore)), .unchanged(.rejectedToken(.wrongProduct))),
            ("licence of another instance", .json(validBody(token: otherInstance)), .unchanged(.rejectedToken(.wrongInstance))),
        ]

        for start in Start.allCases {
            for (name, reply, expected) in rows {
                let rig = Rig(start.stored)
                rig.server.handler = { _ in reply }
                let outcome = await rig.controller.refresh()
                let label = "\(start.rawValue) / \(name)"
                XCTAssertEqual(outcome, expected, label)
                XCTAssertEqual(rig.controller.status, start.status, label)
                XCTAssertEqual(rig.saved, start.stored, label)
                XCTAssertEqual(rig.server.actions, ["validate"], label)
                // And a new launch reads the same state back.
                XCTAssertEqual(Rig(rig.saved).controller.status, start.status, label)
            }
        }
    }

    // MARK: Row 3: a signed revocation locks, and shows the reason

    func testASignedRevocationLocksFromEveryState() async {
        for start in Start.allCases {
            for reason in ["disabled", "refunded", "expired"] {
                let rig = Rig(start.stored)
                let token = TestKeys.token(typ: "revoked", key: key, instanceID: instance, reason: reason)
                rig.server.handler = { _ in .json(revokedBody(token: token), status: 400) }
                let outcome = await rig.controller.refresh()
                XCTAssertEqual(outcome, .revoked, start.rawValue)
                XCTAssertEqual(rig.controller.status, .revoked(reason: reason), start.rawValue)
                XCTAssertFalse(rig.controller.status.isUnlocked)
                // The lock survives a relaunch with no network.
                XCTAssertEqual(Rig(rig.saved).controller.status, .revoked(reason: reason), start.rawValue)
            }
        }
    }

    func testASignedRevocationSignedByTheBackupKeyLocksToo() async {
        let rig = Rig(Start.signed.stored)
        let token = TestKeys.token(kid: "k-test-2", typ: "revoked", key: key, instanceID: nil, reason: "refunded")
        rig.server.handler = { _ in .json(revokedBody(token: token), status: 400) }
        _ = await rig.controller.refresh()
        XCTAssertEqual(rig.controller.status, .revoked(reason: "refunded"))
    }

    /// after a revocation, a new key opens the app again.
    func testAfterARevocationANewKeyOpensTheApp() async throws {
        let rig = Rig(Start.revoked.stored)
        let token = TestKeys.token(key: otherKey, instanceID: newInstance)
        rig.server.handler = { _ in .json(activatedBody(token: token)) }
        try await rig.controller.activate(key: otherKey)
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
        XCTAssertEqual(rig.saved?.licenseKey, otherKey)
        XCTAssertEqual(Rig(rig.saved).controller.status, .licensed(.signed))
    }

    func testARevokedKeyThatIsRestoredOpensAgain() async {
        let rig = Rig(Start.revoked.stored)
        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }
        let outcome = await rig.controller.refresh()
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
    }

    // MARK: A signed licence confirms, from every state

    func testASignedLicenceOpensFromEveryState() async {
        for start in Start.allCases {
            for kid in ["k-test-1", "k-test-2"] {
                let rig = Rig(start.stored)
                let token = TestKeys.token(kid: kid, key: key, instanceID: instance)
                rig.server.handler = { _ in .json(validBody(token: token)) }
                let outcome = await rig.controller.refresh()
                XCTAssertEqual(outcome, .confirmed, start.rawValue)
                XCTAssertEqual(rig.controller.status, .licensed(.signed), start.rawValue)
                XCTAssertEqual(rig.saved?.token, token)
                XCTAssertEqual(rig.saved?.unlocked, true)
                XCTAssertEqual(rig.saved?.lastValidatedAt, rig.clock.now)
                XCTAssertEqual(rig.server.calls.first?.form, ["license_key": key, "instance_id": instance])
            }
        }
    }

    // MARK: Row 4: an unknown instance is answered by activating again, silently

    func testAnUnknownInstanceActivatesAgain() async {
        for start in Start.allCases where start != .revoked {
            let rig = Rig(start.stored)
            let token = TestKeys.token(key: key, instanceID: newInstance)
            rig.server.handler = { call in
                call.action == "validate"
                    ? .json(["valid": false, "error": "instance_id not found."], status: 404)
                    : .json(activatedBody(token: token))
            }
            let outcome = await rig.controller.refresh()
            XCTAssertEqual(outcome, .reactivated, start.rawValue)
            XCTAssertEqual(rig.controller.status, .licensed(.signed), start.rawValue)
            XCTAssertEqual(rig.server.actions, ["validate", "activate"])
            XCTAssertEqual(rig.server.calls[1].form, ["license_key": key, "instance_name": "Test Mac"])
            XCTAssertEqual(rig.saved?.instanceID, newInstance)
            XCTAssertEqual(rig.saved?.token, token)
        }
    }

    func testAFailedReactivationChangesNothing() async {
        let limit: [String: Any?] = [
            "activated": false, "error": "This license key has reached the activation limit.",
            "license_key": ["id": 1, "status": "active", "key": key, "activation_limit": 1, "activation_usage": 1],
            "meta": ["store_id": 100200, "product_id": appProduct, "variant_id": 5100105],
            "token": nil,
        ]
        let replies: [(String, StubProtocol.Reply)] = [
            ("offline", .offline),
            ("503", .json(["activated": false, "error": "x"], status: 503)),
            ("limit", .json(limit, status: 400)),
            ("key not found", .json(["activated": false, "error": "license_key not found."], status: 404)),
        ]
        for start in Start.allCases {
            for (name, reply) in replies {
                let rig = Rig(start.stored)
                rig.server.handler = { call in
                    call.action == "validate" ? .json(["valid": false, "error": "instance_id not found."], status: 404) : reply
                }
                _ = await rig.controller.refresh()
                XCTAssertEqual(rig.controller.status, start.status, "\(start.rawValue) / \(name)")
                XCTAssertEqual(rig.saved, start.stored, "\(start.rawValue) / \(name)")
            }
        }
    }

    func testAReactivationRefusedWithASignedRevocationLocks() async {
        let rig = Rig(Start.signed.stored)
        let token = TestKeys.token(typ: "revoked", key: key, instanceID: nil, reason: "disabled")
        rig.server.handler = { call in
            call.action == "validate"
                ? .json(["valid": false, "error": "instance_id not found."], status: 404)
                : .json(revokedBody(flag: "activated", token: token), status: 400)
        }
        let outcome = await rig.controller.refresh()
        XCTAssertEqual(outcome, .revoked)
        XCTAssertEqual(rig.controller.status, .revoked(reason: "disabled"))
    }

    /// A re-activation whose token cannot be checked must not take a new seat at every check.
    func testAReactivationWithAnUncheckableTokenTakesOneSeatOnly() async {
        let rig = Rig(Start.signed.stored)
        let token = TestKeys.token(kid: "k-test-9", key: key, instanceID: newInstance)
        rig.server.handler = { call in
            if call.action == "activate" { return .json(activatedBody(token: token)) }
            return call.form["instance_id"] == newInstance
                ? .json(validBody(token: token, instanceID: newInstance))
                : .json(["valid": false, "error": "instance_id not found."], status: 404)
        }
        _ = await rig.controller.refresh()
        XCTAssertEqual(rig.controller.status, .licensed(.signed), "still open on the licence it had")
        _ = await rig.controller.refresh()
        _ = await rig.controller.refresh()
        XCTAssertEqual(rig.server.actions.filter { $0 == "activate" }.count, 1)
        XCTAssertTrue(rig.controller.status.isUnlocked)
    }

    func testAKeyWithoutAnInstanceIsActivated() async {
        let rig = Rig(StoredLicense(licenseKey: key, instanceID: nil, unlocked: true))
        let token = TestKeys.token(key: key, instanceID: newInstance)
        rig.server.handler = { _ in .json(activatedBody(token: token)) }
        let outcome = await rig.controller.refresh()
        XCTAssertEqual(outcome, .reactivated)
        XCTAssertEqual(rig.server.actions, ["activate"])
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
    }

    // MARK: Row 5: a signed licence past its expiry: online validation, 14 days of grace

    func testAnExpiredSubscriptionHasFourteenDaysOfGrace() async {
        let clock = TestClock("2026-12-20T00:00:00Z")
        let exp = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        let stored = StoredLicense(
            licenseKey: key, instanceID: instance,
            token: TestKeys.token(key: key, instanceID: instance, exp: exp),
            unlocked: true, lastValidatedAt: clock.now
        )
        func status(at iso: String, mark: Date? = nil) -> LicenseStatus {
            var s = stored
            s.highWaterMark = mark
            let rig = Rig(s)
            rig.clock.now = ISO8601DateFormatter().date(from: iso)!
            // The status is computed at init with the rig's default clock; ask again through a relaunch.
            let storage = InMemoryLicenseStorage(s)
            let at = rig.clock.now
            let controller = LicenseController(
                configuration: LicenseConfiguration(baseURL: rig.server.baseURL, publicKeys: TestKeys.trusted, productIDs: [appProduct]),
                storage: storage, session: rig.server.session, now: { at }
            )
            return controller.status
        }
        XCTAssertEqual(status(at: "2026-12-20T00:00:00Z"), .licensed(.signed))
        XCTAssertEqual(status(at: "2027-01-10T00:00:00Z"), .licensed(.grace))
        XCTAssertEqual(status(at: "2027-01-15T00:00:00Z"), .licensed(.grace))
        XCTAssertEqual(status(at: "2027-01-15T00:00:01Z"), .expired)
        // The clock set back does not bring an expired licence back.
        let mark = ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z")!
        XCTAssertEqual(status(at: "2026-12-20T00:00:00Z", mark: mark), .expired)
    }

    func testInGraceTheServerIsAskedAtOnceAndARenewalRestoresTheLicence() async {
        let exp = ISO8601DateFormatter().date(from: "2026-11-25T00:00:00Z")!  // the rig's clock is 2026-12-02
        let rig = Rig(StoredLicense(
            licenseKey: key, instanceID: instance,
            token: TestKeys.token(key: key, instanceID: instance, exp: exp),
            unlocked: true, lastValidatedAt: TestClock().now.addingTimeInterval(-3600)
        ))
        XCTAssertEqual(rig.controller.status, .licensed(.grace))

        // Offline: stays open in grace, although it was validated an hour ago the check is due.
        rig.server.handler = { _ in .offline }
        var outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .unchanged(.serverUnavailable))
        XCTAssertEqual(rig.controller.status, .licensed(.grace))

        // The renewal arrives.
        let renewed = TestKeys.token(key: key, instanceID: instance, exp: exp.addingTimeInterval(365 * day))
        rig.server.handler = { _ in .json(validBody(token: renewed)) }
        rig.clock.advance(3600)
        outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
    }

    func testPastTheGraceTheAppLocksAsExpiredAndTheHighWaterMarkIsKept() async {
        let exp = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
        let rig = Rig(StoredLicense(
            licenseKey: key, instanceID: instance,
            token: TestKeys.token(key: key, instanceID: instance, exp: exp), unlocked: true
        ))
        XCTAssertEqual(rig.controller.status, .expired)
        rig.server.handler = { _ in .offline }
        _ = await rig.controller.refresh()
        XCTAssertEqual(rig.saved?.highWaterMark, rig.clock.now)
        XCTAssertEqual(rig.controller.status, .expired)
    }

    func testAPerpetualLicenceIgnoresTheClock() {
        for iso in ["2020-01-01T00:00:00Z", "2040-01-01T00:00:00Z"] {
            let at = ISO8601DateFormatter().date(from: iso)!
            let server = FakeServer()
            let controller = LicenseController(
                configuration: LicenseConfiguration(baseURL: server.baseURL, publicKeys: TestKeys.trusted),
                storage: InMemoryLicenseStorage(Start.signed.stored), session: server.session, now: { at }
            )
            XCTAssertEqual(controller.status, .licensed(.signed), iso)
        }
    }

    // MARK: At most once a day, in the background

    func testOnlineValidationHappensAtMostOnceADay() async {
        let rig = Rig(Start.signed.stored)
        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }

        var outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .confirmed, "never validated: due")
        for hours in [1.0, 6, 12, 4.9] {
            rig.clock.advance(hours * 3600)
            outcome = await rig.controller.refreshIfDue()
            XCTAssertEqual(outcome, .notDue)
        }
        XCTAssertEqual(rig.server.calls.count, 1)

        rig.clock.advance(0.2 * 3600)
        outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .confirmed, "a day has passed")
        XCTAssertEqual(rig.server.calls.count, 2)

        // A relaunch inside the day does not ask again.
        let relaunched = Rig(rig.saved)
        relaunched.clock.now = rig.clock.now.addingTimeInterval(3600)
        outcome = await relaunched.controller.refreshIfDue()
        XCTAssertEqual(outcome, .notDue)
        XCTAssertEqual(relaunched.server.calls.count, 0)
    }

    func testAFailedCheckIsRetriedAfterTheRetryIntervalAndAtTheNextLaunch() async {
        let rig = Rig(Start.signed.stored)
        rig.server.handler = { _ in .offline }
        var outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .unchanged(.serverUnavailable))
        rig.clock.advance(60)
        outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .notDue)
        rig.clock.advance(15 * 60)
        outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .unchanged(.serverUnavailable))
        XCTAssertEqual(rig.server.calls.count, 2)

        let relaunched = Rig(rig.saved)
        relaunched.server.handler = { _ in .offline }
        outcome = await relaunched.controller.refreshIfDue()
        XCTAssertEqual(outcome, .unchanged(.serverUnavailable), "a new launch tries again at once")
    }

    func testAClockSetBackMakesTheCheckDue() async {
        var stored = Start.signed.stored
        stored.lastValidatedAt = TestClock().now.addingTimeInterval(30 * day)
        let rig = Rig(stored)
        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }
        let outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .confirmed)
    }

    func testNothingStoredAsksNothing() async {
        let rig = Rig(nil)
        let a = await rig.controller.refreshIfDue()
        let b = await rig.controller.refresh()
        XCTAssertEqual(a, .noLicense)
        XCTAssertEqual(b, .noLicense)
        XCTAssertEqual(rig.server.calls.count, 0)
    }

    // MARK: Upgrade from a version without signed licences

    func testUpgradeReadsTheOldStateAndGetsASignedLicenceWithoutTheUser() async {
        let rig = Rig(nil, legacy: LegacyLicense(licenseKey: " \(key)\n", instanceID: instance, wasUnlocked: true))
        XCTAssertEqual(rig.controller.status, .licensed(.unverified), "open before any request")
        XCTAssertTrue(rig.controller.isAwaitingFirstConfirmation)
        XCTAssertEqual(rig.saved, StoredLicense(licenseKey: key, instanceID: instance, unlocked: true))

        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }
        let outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(rig.server.calls.map(\.form), [["license_key": key, "instance_id": instance]])
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
        XCTAssertFalse(rig.controller.isAwaitingFirstConfirmation)
        XCTAssertEqual(rig.saved?.token, token)
    }

    func testUpgradeWhileTheServerIsDownStaysOpenAndTriesAgainNextLaunch() async {
        let legacy = LegacyLicense(licenseKey: key, instanceID: instance, wasUnlocked: true)
        var saved: StoredLicense?
        // Three launches with the server down in a different way each time.
        for reply in [StubProtocol.Reply.offline, .json(["valid": false, "error": "x"], status: 503), .raw("<html>")] {
            let rig = Rig(saved, legacy: legacy)
            rig.server.handler = { _ in reply }
            let outcome = await rig.controller.refreshIfDue()
            XCTAssertEqual(outcome, .unchanged(.serverUnavailable))
            XCTAssertEqual(rig.controller.status, .licensed(.unverified))
            XCTAssertEqual(rig.server.calls.count, 1, "every launch tries")
            saved = rig.saved
        }
        // The server is back.
        let rig = Rig(saved, legacy: legacy)
        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }
        let outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
    }

    func testUpgradeWhoseInstanceTheServerDoesNotKnowActivatesAgain() async {
        let rig = Rig(nil, legacy: LegacyLicense(licenseKey: key, instanceID: instance, wasUnlocked: true))
        let token = TestKeys.token(key: key, instanceID: newInstance)
        rig.server.handler = { call in
            call.action == "validate"
                ? .json(["valid": false, "error": "instance_id not found."], status: 404)
                : .json(activatedBody(token: token))
        }
        let outcome = await rig.controller.refreshIfDue()
        XCTAssertEqual(outcome, .reactivated)
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
    }

    func testUpgradeOfAnAppTheOldVersionHadLockedStaysLockedUntilConfirmed() async {
        let rig = Rig(nil, legacy: LegacyLicense(licenseKey: key, instanceID: instance, wasUnlocked: false))
        XCTAssertEqual(rig.controller.status, .unlicensed)
        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }
        _ = await rig.controller.refreshIfDue()
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
    }

    func testTheOldStateIsNotReadOnceSomethingIsStored() {
        let rig = Rig(Start.signed.stored, legacy: LegacyLicense(licenseKey: otherKey, instanceID: "x", wasUnlocked: true))
        XCTAssertEqual(rig.controller.licenseKey, key)
    }

    func testNoOldStateAndNothingStoredIsUnlicensed() {
        XCTAssertEqual(Rig(nil, legacy: nil).controller.status, .unlicensed)
        XCTAssertEqual(Rig(nil, legacy: LegacyLicense(licenseKey: "  ", instanceID: nil, wasUnlocked: true)).controller.status, .unlicensed)
    }

    func testAKeychainThatRefusesWritesDoesNotLockTheUpgrade() async {
        let rig = Rig(nil)
        rig.storage.failWrites = true
        let server = FakeServer()
        let controller = LicenseController(
            configuration: LicenseConfiguration(baseURL: server.baseURL, publicKeys: TestKeys.trusted, productIDs: [appProduct]),
            storage: rig.storage,
            legacy: { LegacyLicense(licenseKey: key, instanceID: instance, wasUnlocked: true) },
            session: server.session
        )
        XCTAssertEqual(controller.status, .licensed(.unverified))
        let token = TestKeys.token(key: key, instanceID: instance)
        server.handler = { _ in .json(validBody(token: token)) }
        _ = await controller.refresh()
        XCTAssertEqual(controller.status, .licensed(.signed))
    }

    // MARK: What the user does

    func testActivatingAKeyStoresTheSignedLicence() async throws {
        let rig = Rig(nil)
        let token = TestKeys.token(key: key, instanceID: newInstance)
        rig.server.handler = { _ in .json(activatedBody(token: token)) }
        try await rig.controller.activate(key: "  \(key.uppercased()) ")
        XCTAssertEqual(rig.controller.status, .licensed(.signed))
        XCTAssertEqual(rig.server.calls.map(\.form), [["license_key": key.uppercased(), "instance_name": "Test Mac"]])
        XCTAssertEqual(
            rig.saved,
            StoredLicense(
                licenseKey: key.uppercased(), instanceID: newInstance, token: token, unlocked: true,
                lastValidatedAt: rig.clock.now, highWaterMark: rig.clock.now
            )
        )
        // And the app opens offline at the next launch.
        XCTAssertEqual(Rig(rig.saved).controller.status, .licensed(.signed))
    }

    func testActivationFailuresSayWhyAndChangeNothing() async {
        let limit: [String: Any?] = [
            "activated": false, "error": "This license key has reached the activation limit.",
            "license_key": ["id": 1, "status": "active", "key": key, "activation_limit": 1, "activation_usage": 1],
            "meta": ["store_id": 100200, "product_id": appProduct, "variant_id": 5100105], "token": nil,
        ]
        let revoked = TestKeys.token(typ: "revoked", key: otherKey, instanceID: nil, reason: "refunded")
        let rows: [(String, StubProtocol.Reply, LicenseError)] = [
            ("offline", .offline, .serverUnavailable),
            ("503", .json(["activated": false, "error": "x"], status: 503), .serverUnavailable),
            ("429", .json(["activated": false, "error": "x"], status: 429), .serverUnavailable),
            ("garbled", .raw("<html>"), .serverUnavailable),
            ("not found", .json(["activated": false, "error": "license_key not found."], status: 404), .keyNotFound),
            ("limit", .json(limit, status: 400), .activationLimitReached),
            ("422", .json(["message": "The license key field is required."], status: 422), .server("The license key field is required.")),
            ("signed revocation", .json(revokedBody(flag: "activated", token: revoked), status: 400), .revoked(reason: "refunded")),
            ("activated without a token", .json(activatedBody(token: nil)), .unverifiableAnswer),
        ]
        for start in [Start.signed, .keyButLocked] {
            for (name, reply, expected) in rows {
                let rig = Rig(start.stored)
                rig.server.handler = { _ in reply }
                do {
                    try await rig.controller.activate(key: otherKey)
                    XCTFail("\(name): must throw")
                } catch {
                    XCTAssertEqual(error as? LicenseError, expected, name)
                }
                XCTAssertEqual(rig.controller.status, start.status, name)
                XCTAssertEqual(rig.saved, start.stored, name)
            }
        }
        let rig = Rig(nil)
        do { try await rig.controller.activate(key: "   "); XCTFail() } catch { XCTAssertEqual(error as? LicenseError, .emptyKey) }
        XCTAssertEqual(rig.server.calls.count, 0)
    }

    /// a key of another product is refused clearly, and the seat it took is given back.
    func testANewActivationKeepsTheLatestTimeSeen() async throws {
        let later = TestClock().now.addingTimeInterval(90 * day)
        var start = Start.signed.stored
        start.highWaterMark = later
        let rig = Rig(start)
        let token = TestKeys.token(key: otherKey, instanceID: newInstance)
        rig.server.handler = { _ in .json(activatedBody(token: token)) }
        try await rig.controller.activate(key: otherKey)
        XCTAssertEqual(rig.saved?.highWaterMark, later, "a clock set back before the activation stays set back")
    }

    func testAnActivationIsJudgedAgainstTheLatestTimeSeen() async {
        // The device has seen a time past this subscription's expiry and grace.
        let clock = TestClock()
        var start = Start.signed.stored
        start.highWaterMark = clock.now.addingTimeInterval(60 * day)
        let rig = Rig(start)
        let token = TestKeys.token(key: otherKey, instanceID: newInstance, exp: clock.now.addingTimeInterval(10 * day))
        rig.server.handler = { call in
            call.action == "activate"
                ? .json(activatedBody(token: token))
                : .json(["deactivated": true, "error": nil, "token": nil])
        }
        do {
            try await rig.controller.activate(key: otherKey)
            XCTFail("an expired licence must not activate")
        } catch {}
        XCTAssertEqual(rig.saved?.licenseKey, key, "the previous licence is kept")
        XCTAssertEqual(rig.server.actions, ["activate", "deactivate"], "and the seat is given back")
    }

    func testTheMarkMovesAtLaunch() {
        // A subscription stored with no mark yet: the first launch records the time.
        let clock = TestClock()
        let token = TestKeys.token(key: key, instanceID: instance, exp: clock.now.addingTimeInterval(30 * day))
        let rig = Rig(StoredLicense(licenseKey: key, instanceID: instance, token: token, unlocked: true))
        XCTAssertEqual(rig.saved?.highWaterMark, rig.clock.now)
    }

    func testALicenceThatCannotBeStoredGivesItsSeatBack() async {
        let rig = Rig(nil)
        rig.storage.failWrites = true
        let token = TestKeys.token(key: key, instanceID: newInstance)
        rig.server.handler = { call in
            call.action == "activate"
                ? .json(activatedBody(token: token))
                : .json(["deactivated": true, "error": nil, "token": nil])
        }
        do {
            try await rig.controller.activate(key: key)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? LicenseError, .storageFailed)
        }
        XCTAssertEqual(rig.controller.status, .unlicensed)
        XCTAssertEqual(rig.server.actions, ["activate", "deactivate"])
        XCTAssertEqual(rig.server.calls[1].form, ["license_key": key, "instance_id": newInstance])
    }

    func testAnActivationWithoutALicenceGivesItsSeatBack() async {
        let rig = Rig(nil)
        rig.server.handler = { call in
            call.action == "activate"
                ? .json(activatedBody(token: nil))
                : .json(["deactivated": true, "error": nil, "token": nil])
        }
        do {
            try await rig.controller.activate(key: key)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? LicenseError, .unverifiableAnswer)
        }
        XCTAssertNil(rig.saved)
        XCTAssertEqual(rig.server.actions, ["activate", "deactivate"])
    }

    func testAKeyOfAnotherProductIsRefusedAndItsSeatReleased() async {
        for start in [nil, Start.signed.stored] as [StoredLicense?] {
            let rig = Rig(start)
            let before = rig.controller.status
            let token = TestKeys.token(key: otherKey, productID: 4100106, variantID: 5100106, instanceID: newInstance)
            rig.server.handler = { call in
                call.action == "activate"
                    ? .json(activatedBody(token: token, product: 4100106))
                    : .json(["deactivated": true, "error": nil, "token": nil])
            }
            do {
                try await rig.controller.activate(key: otherKey)
                XCTFail("must throw")
            } catch {
                XCTAssertEqual(error as? LicenseError, .wrongProduct)
            }
            XCTAssertEqual(rig.controller.status, before)
            XCTAssertEqual(rig.saved, start)
            XCTAssertEqual(rig.server.actions, ["activate", "deactivate"])
            XCTAssertEqual(rig.server.calls[1].form, ["license_key": otherKey, "instance_id": newInstance])
        }
    }

    func testAnActivationSignedByAnUnknownKeyDoesNotOpenAndReleasesTheSeat() async {
        let rig = Rig(nil)
        let token = TestKeys.token(kid: "k-test-9", key: key, instanceID: newInstance)
        rig.server.handler = { call in
            call.action == "activate" ? .json(activatedBody(token: token)) : .json(["deactivated": true, "error": nil])
        }
        do { try await rig.controller.activate(key: key); XCTFail() } catch {
            XCTAssertEqual(error as? LicenseError, .unverifiableAnswer)
        }
        XCTAssertEqual(rig.controller.status, .unlicensed)
        XCTAssertEqual(rig.server.actions, ["activate", "deactivate"])
    }

    func testActivatingTheRunningKeyThatWasRevokedLocks() async {
        let rig = Rig(Start.signed.stored)
        let token = TestKeys.token(typ: "revoked", key: key, instanceID: nil, reason: "disabled")
        rig.server.handler = { _ in .json(revokedBody(flag: "activated", token: token), status: 400) }
        do { try await rig.controller.activate(key: key); XCTFail() } catch {
            XCTAssertEqual(error as? LicenseError, .revoked(reason: "disabled"))
        }
        XCTAssertEqual(rig.controller.status, .revoked(reason: "disabled"))
    }

    /// enter a key, activate, deactivate, activate elsewhere.
    func testDeactivateGivesTheSeatBackAndForgetsTheLicence() async throws {
        let rig = Rig(Start.signed.stored)
        rig.server.handler = { _ in .json(["deactivated": true, "error": nil, "token": nil]) }
        try await rig.controller.deactivate()
        XCTAssertEqual(rig.controller.status, .unlicensed)
        XCTAssertNil(rig.saved)
        XCTAssertEqual(rig.server.calls.map(\.form), [["license_key": key, "instance_id": instance]])
        XCTAssertEqual(Rig(rig.saved).controller.status, .unlicensed)
    }

    func testDeactivateOfASeatTheServerNoLongerKnowsStillForgetsTheLicence() async throws {
        let rig = Rig(Start.signed.stored)
        rig.server.handler = { _ in .json(["deactivated": false, "error": "instance_id not found."], status: 404) }
        try await rig.controller.deactivate()
        XCTAssertEqual(rig.controller.status, .unlicensed)
        XCTAssertNil(rig.saved)
    }

    func testDeactivateWhileTheServerIsDownKeepsTheLicence() async {
        for reply in [StubProtocol.Reply.offline, .json(["deactivated": false, "error": "x"], status: 500)] {
            let rig = Rig(Start.signed.stored)
            rig.server.handler = { _ in reply }
            do { try await rig.controller.deactivate(); XCTFail() } catch {
                XCTAssertEqual(error as? LicenseError, .serverUnavailable)
            }
            XCTAssertEqual(rig.controller.status, .licensed(.signed))
            XCTAssertEqual(rig.saved, Start.signed.stored)
        }
    }

    // MARK: A stored token this build cannot read

    func testAStoredTokenOfAnUnknownKeyKeepsThePreviousState() async {
        for unlocked in [true, false] {
            let stored = StoredLicense(
                licenseKey: key, instanceID: instance,
                token: TestKeys.token(kid: "k-test-9", key: key, instanceID: instance), unlocked: unlocked
            )
            let rig = Rig(stored)
            XCTAssertEqual(rig.controller.status, unlocked ? .licensed(.unverified) : .unlicensed)
            // And it asks the server at once rather than waiting a day.
            rig.server.handler = { _ in .offline }
            let outcome = await rig.controller.refreshIfDue()
            XCTAssertEqual(outcome, .unchanged(.serverUnavailable))
        }
    }

    func testConcurrentRefreshesShareOneRequest() async {
        let rig = Rig(Start.signed.stored)
        let token = TestKeys.token(key: key, instanceID: instance)
        rig.server.handler = { _ in .json(validBody(token: token)) }
        async let a = rig.controller.refresh()
        async let b = rig.controller.refresh()
        let outcomes = await [a, b]
        XCTAssertEqual(outcomes, [.confirmed, .confirmed])
        XCTAssertEqual(rig.server.calls.count, 1)
    }
}
