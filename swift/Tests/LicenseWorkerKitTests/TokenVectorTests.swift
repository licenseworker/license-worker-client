import CryptoKit
import XCTest
@testable import LicenseWorkerKit
import LicenseWorkerKitTesting

/// Every shared vector, with the verdict and the reason PROTOCOL.md gives.
final class TokenVectorTests: XCTestCase {
    struct Vectors {
        let root: [String: Any]
        var cases: [[String: Any]] { root["cases"] as! [[String: Any]] }
        var keys: [String: [String: String]] { root["keys"] as! [String: [String: String]] }
        var trusted: [String: String] {
            var result: [String: String] = [:]
            for kid in root["trusted_kids"] as! [String] { result[kid] = keys[kid]!["public_key_b64"]! }
            return result
        }
    }

    static func loadVectors() throws -> Vectors {
        // The repository's single copy, shared with the Rust tests.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/vectors/license-token-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Vectors(root: root)
    }

    func testEveryVectorReachesTheReferenceVerdict() throws {
        let vectors = try Self.loadVectors()
        XCTAssertEqual(vectors.cases.count, 16, "the vector file changed size; review the new cases")
        let grace = TimeInterval(vectors.root["default_grace_seconds"] as! Int)
        let verifier = LicenseTokenVerifier(publicKeys: vectors.trusted, graceSeconds: grace)
        let iso = ISO8601DateFormatter()

        for c in vectors.cases {
            let name = c["name"] as! String
            let verify = c["verify"] as! [String: Any]
            let expect = verify["expect"] as? [String: Any] ?? [:]
            let expectation = TokenExpectation(
                keyHash: expect["key_hash"] as? String,
                productIDs: expect["product_ids"] as? [Int],
                variantIDs: expect["variant_ids"] as? [Int],
                instanceID: expect["instance_id"] as? String
            )
            let verdict = verifier.verify(
                c["token"] as! String,
                expecting: expectation,
                now: iso.date(from: verify["now"] as! String)!,
                highWaterMark: (verify["high_water_mark"] as? String).flatMap(iso.date(from:))
            )

            let expected = c["expected"] as! [String: Any]
            if expected["ok"] as! Bool {
                let state: String
                switch verdict {
                case .valid: state = "valid"
                case .grace: state = "grace"
                case .revoked: state = "revoked"
                case .rejected(let reason, _): state = "rejected(\(reason.rawValue))"
                }
                XCTAssertEqual(state, expected["state"] as? String, name)
            } else {
                guard case .rejected(let reason, _) = verdict else {
                    XCTFail("\(name): expected a rejection, got \(verdict)")
                    continue
                }
                let acceptable = [expected["reason"] as! String] + (expected["also_acceptable"] as? [String] ?? [])
                XCTAssertTrue(acceptable.contains(reason.rawValue), "\(name): \(reason.rawValue) not in \(acceptable)")
                // The reference's own reason is the one this verifier should give.
                XCTAssertEqual(reason.rawValue, expected["reason"] as? String, name)
            }
        }
    }

    func testAcceptedPayloadsMatchTheVectorPayloads() throws {
        let vectors = try Self.loadVectors()
        let verifier = LicenseTokenVerifier(publicKeys: vectors.trusted)
        var compared = 0
        for c in vectors.cases {
            // Not every case lists its payload.
            guard let p = c["payload"] as? [String: Any] else { continue }
            let verdict = verifier.verify(c["token"] as! String, now: Date(timeIntervalSince1970: 0))
            let payload: LicenseTokenPayload
            switch verdict {
            case .valid(let x), .grace(let x), .revoked(let x): payload = x
            case .rejected(_, let x):
                // Rejected before the signature held: no payload is exposed.
                guard let x else { continue }
                payload = x
            }
            compared += 1
            XCTAssertEqual(payload.kid, p["kid"] as? String)
            XCTAssertEqual(payload.kind.rawValue, p["typ"] as? String)
            XCTAssertEqual(payload.keyHash, p["key_hash"] as? String)
            XCTAssertEqual(payload.storeID, p["store_id"] as? Int)
            XCTAssertEqual(payload.productID, p["product_id"] as? Int)
            XCTAssertEqual(payload.variantID, p["variant_id"] as? Int)
            XCTAssertEqual(payload.instanceID, p["instance_id"] as? String)
            XCTAssertEqual(payload.issuedAt, p["iat"] as? Int)
            XCTAssertEqual(payload.expiresAt, p["exp"] as? Int)
            XCTAssertEqual(payload.reason, p["reason"] as? String)
        }
        XCTAssertGreaterThanOrEqual(compared, 5)
    }

    func testKeyHashRule() throws {
        let vectors = try Self.loadVectors()
        let key = vectors.root["license_key"] as! String
        let hash = vectors.root["key_hash"] as! String
        XCTAssertEqual(LicenseKeyHash.hash(key), hash)
        XCTAssertEqual(LicenseKeyHash.hash("  \(key.uppercased())\n"), hash)
    }

    func testSeedsDeriveTheStatedPublicKeys() throws {
        let vectors = try Self.loadVectors()
        for (kid, key) in vectors.keys {
            let seed = try XCTUnwrap(Data(base64Encoded: key["seed_b64"]!))
            let derived = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
            XCTAssertEqual(derived.base64EncodedString(), key["public_key_b64"], kid)
        }
    }

    /// The other direction: a token signed here verifies here, and a
    /// changed byte does not.
    func testATokenSignedInSwiftVerifies() {
        let key = "38b1460a-5104-4067-a91d-77b872934d51"
        let token = TestKeys.token(key: key, instanceID: "i-1")
        let verifier = LicenseTokenVerifier(publicKeys: TestKeys.trusted)
        let expectation = TokenExpectation(keyHash: LicenseKeyHash.hash(key), productIDs: [4100105], instanceID: "i-1")
        guard case .valid = verifier.verify(token, expecting: expectation, now: Date()) else {
            return XCTFail("a Swift-signed token must verify")
        }
        var chars = Array(token)
        let i = chars.count - 5
        chars[i] = chars[i] == "A" ? "B" : "A"
        XCTAssertEqual(verifier.verify(String(chars), expecting: expectation, now: Date()), .rejected(.badSignature, nil))
    }

    func testStoreIsChecked() {
        let key = "k"
        let token = TestKeys.token(key: key, storeID: 1, instanceID: nil)
        let verifier = LicenseTokenVerifier(publicKeys: TestKeys.trusted)
        guard case .rejected(.wrongProduct, _) = verifier.verify(token, expecting: TokenExpectation(storeID: 100200), now: Date()) else {
            return XCTFail("a licence of another store must be rejected")
        }
    }
}
