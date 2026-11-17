import XCTest
@testable import LicenseWorkerKit
import LicenseWorkerKitTesting

final class ClientTests: XCTestCase {
    func testRequestsAreFormEncodedAndAskForJSON() async {
        let server = FakeServer()
        server.handler = { _ in .json(["valid": true, "error": nil]) }
        let client = LicenseClient(baseURL: server.baseURL, session: server.session)

        _ = await client.activate(licenseKey: "AB CD+&=é", instanceName: "Dana's Mac")
        _ = await client.validate(licenseKey: "k", instanceID: "i")
        _ = await client.validate(licenseKey: "k", instanceID: nil)
        _ = await client.deactivate(licenseKey: "k", instanceID: "i")

        let calls = server.calls
        XCTAssertEqual(calls.map(\.action), ["activate", "validate", "validate", "deactivate"])
        for call in calls {
            XCTAssertEqual(call.headers["Content-Type"], "application/x-www-form-urlencoded")
            XCTAssertEqual(call.headers["Accept"], "application/json")
            XCTAssertNil(call.headers["Authorization"])
        }
        XCTAssertEqual(calls[0].form, ["license_key": "AB CD+&=é", "instance_name": "Dana's Mac"])
        XCTAssertFalse(calls[0].rawBody.contains(" "))
        XCTAssertFalse(calls[0].rawBody.contains("+"))
        XCTAssertEqual(calls[1].form, ["license_key": "k", "instance_id": "i"])
        XCTAssertEqual(calls[2].form, ["license_key": "k"])
        XCTAssertEqual(calls[3].form, ["license_key": "k", "instance_id": "i"])
    }

    func testThePathIsUnderV1Licenses() async {
        let server = FakeServer()
        let seen = expectation(description: "request")
        StubProtocol.register(host: server.host) { _ in seen.fulfill(); return .json([:]) }
        let session = server.session
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v1/licenses/validate"))
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
        await fulfillment(of: [seen], timeout: 2)
        XCTAssertEqual(
            URL(string: "https://license.example.com")!.appendingPathComponent("v1/licenses/activate").absoluteString,
            "https://license.example.com/v1/licenses/activate"
        )
    }

    func testAnswersThatAreNotAnswers() async {
        let server = FakeServer()
        let client = LicenseClient(baseURL: server.baseURL, session: server.session)

        server.handler = { _ in .offline }
        guard case .unavailable(.network) = await client.validate(licenseKey: "k", instanceID: nil) else {
            return XCTFail("a network error is not an answer")
        }
        server.handler = { _ in .json(["valid": false, "error": "x"], status: 429) }
        var answer = await client.validate(licenseKey: "k", instanceID: nil)
        XCTAssertEqual(answer, .unavailable(.rateLimited))

        for status in [500, 502, 503, 504] {
            server.handler = { _ in .json(["valid": false, "error": "x"], status: status) }
            answer = await client.validate(licenseKey: "k", instanceID: nil)
            XCTAssertEqual(answer, .unavailable(.serverError(status)))
        }
        for body in ["<html>captive portal</html>", "", "[1,2]", "\"text\"", "{\"valid\": tru"] {
            server.handler = { _ in .raw(body) }
            answer = await client.validate(licenseKey: "k", instanceID: nil)
            XCTAssertEqual(answer, .unavailable(.garbled), body)
        }
    }

    /// The real failure bodies, as recorded from the live License API.
    func testRecordedFailureShapesDecode() async {
        let server = FakeServer()
        let client = LicenseClient(baseURL: server.baseURL, session: server.session)

        server.handler = { _ in .json(["valid": false, "error": "license_key not found."], status: 404) }
        guard case .answered(let notFound, 404) = await client.validate(licenseKey: "k", instanceID: nil) else {
            return XCTFail()
        }
        XCTAssertEqual(notFound.valid, false)
        XCTAssertEqual(notFound.error, ServerErrorText.keyNotFound)
        XCTAssertNil(notFound.token)

        server.handler = { _ in
            .json([
                "message": "The license key field is required.",
                "errors": ["license_key": ["The license key field is required."]],
            ], status: 422)
        }
        guard case .answered(let missing, 422) = await client.validate(licenseKey: "", instanceID: nil) else {
            return XCTFail()
        }
        XCTAssertNil(missing.valid)
        XCTAssertEqual(missing.error, "The license key field is required.")

        server.handler = { _ in
            .json([
                "activated": true, "error": nil,
                "license_key": ["id": 1, "status": "active", "key": "k", "activation_limit": 3, "activation_usage": 1],
                "instance": ["id": "i-9", "name": "Mac"],
                "meta": ["store_id": 100200, "product_id": 4100105, "variant_id": 5100105],
                "token": "v1.a.b",
            ])
        }
        guard case .answered(let ok, 200) = await client.activate(licenseKey: "k", instanceName: "Mac") else {
            return XCTFail()
        }
        XCTAssertEqual(ok.activated, true)
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.licenseStatus, "active")
        XCTAssertEqual(ok.activationLimit, 3)
        XCTAssertEqual(ok.instanceID, "i-9")
        XCTAssertEqual(ok.storeID, 100200)
        XCTAssertEqual(ok.productID, 4100105)
        XCTAssertEqual(ok.variantID, 5100105)
        XCTAssertEqual(ok.token, "v1.a.b")
    }
}
