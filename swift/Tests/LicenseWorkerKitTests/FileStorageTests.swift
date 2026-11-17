import XCTest
@testable import LicenseWorkerKit

final class FileStorageTests: XCTestCase {
    func testRoundTripAndClear() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lwkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileLicenseStorage(url: dir.appendingPathComponent("nested/licence.json"))
        XCTAssertNil(try storage.load())
        try storage.clear() // nothing there: not an error
        let license = StoredLicense(
            licenseKey: "k", instanceID: "i", token: "t", unlocked: true,
            lastValidatedAt: Date(timeIntervalSince1970: 1_796_126_400), highWaterMark: Date(timeIntervalSince1970: 1_796_126_500)
        )
        try storage.save(license)
        XCTAssertEqual(try storage.load(), license)
        try storage.clear()
        XCTAssertNil(try storage.load())
    }

    func testAnUnreadableFileIsAbsent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lwkit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(try FileLicenseStorage(url: url).load())
    }

    func testTheDefaultInstanceNameIsNotEmpty() {
        XCTAssertFalse(LicenseController.defaultInstanceName().isEmpty)
    }
}
