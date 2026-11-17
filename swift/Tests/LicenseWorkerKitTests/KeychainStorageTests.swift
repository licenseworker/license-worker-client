import XCTest
@testable import LicenseWorkerKit

final class KeychainStorageTests: XCTestCase {
    func testRoundTripInTheRealKeychain() throws {
        let storage = KeychainLicenseStorage(service: "com.example.LicenseWorkerKitTests.\(UUID().uuidString)")
        defer { try? storage.clear() }
        do {
            let initial = try storage.load()
            XCTAssertNil(initial)
        } catch {
            throw XCTSkip("no usable keychain in this environment: \(error)")
        }

        var license = StoredLicense(
            licenseKey: "38b1460a-5104-4067-a91d-77b872934d51", instanceID: "i-1", token: "v1.x.y",
            unlocked: true, lastValidatedAt: Date(timeIntervalSince1970: 1_796_126_400)
        )
        do {
            try storage.save(license)
        } catch {
            throw XCTSkip("the keychain refused a write in this environment: \(error)")
        }
        XCTAssertEqual(try storage.load(), license)

        license.token = "v1.new.token"
        license.instanceID = nil
        try storage.save(license)
        XCTAssertEqual(try storage.load(), license)

        try storage.clear()
        XCTAssertNil(try storage.load())
        try storage.clear()
    }

    func testTwoServicesDoNotSeeEachOther() throws {
        let a = KeychainLicenseStorage(service: "com.example.LicenseWorkerKitTests.a.\(UUID().uuidString)")
        let b = KeychainLicenseStorage(service: "com.example.LicenseWorkerKitTests.b.\(UUID().uuidString)")
        defer { try? a.clear(); try? b.clear() }
        do {
            try a.save(StoredLicense(licenseKey: "A"))
        } catch {
            throw XCTSkip("no usable keychain in this environment: \(error)")
        }
        XCTAssertNil(try b.load())
        XCTAssertEqual(try a.load()?.licenseKey, "A")
    }
}
