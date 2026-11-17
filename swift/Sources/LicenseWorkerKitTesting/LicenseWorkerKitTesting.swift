// Test doubles for LicenseWorkerKit and for the apps that use it: a scripted licence
// server, a signer with the published throwaway test keys, and a movable clock.
// Never link this into an app.
import CryptoKit
import Foundation
import LicenseWorkerKit

/// Answers requests of a URLSession without a network. Each test gets its own
/// host, so handlers never leak between tests.
public final class StubProtocol: URLProtocol {
    public struct Reply {
        public var status: Int = 200
        public var body: Data = Data()
        public var error: Error?
        public init(status: Int = 200, body: Data = Data(), error: Error? = nil) {
            self.status = status
            self.body = body
            self.error = error
        }
        public static func json(_ object: [String: Any?], status: Int = 200) -> Reply {
            let clean = object.mapValues { $0 ?? NSNull() as Any }
            return Reply(status: status, body: try! JSONSerialization.data(withJSONObject: clean))
        }
        public static func raw(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
        public static let offline = Reply(error: URLError(.notConnectedToInternet))
    }

    public struct Call {
        public let action: String
        public let form: [String: String]
        public let headers: [String: String]
        public let rawBody: String
    }

    private static let lock = NSLock()
    private static var handlers: [String: (Call) -> Reply] = [:]

    public static func register(host: String, _ handler: @escaping (Call) -> Reply) {
        lock.lock(); handlers[host] = handler; lock.unlock()
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func stopLoading() {}

    public override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let raw = String(decoding: data, as: UTF8.self)
        var form: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if kv.count == 2 { form[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        let call = Call(
            action: request.url!.lastPathComponent, form: form,
            headers: request.allHTTPHeaderFields ?? [:], rawBody: raw
        )
        Self.lock.lock()
        let handler = Self.handlers[request.url!.host ?? ""]
        Self.lock.unlock()
        let reply = handler?(call) ?? .offline
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A scripted server: records every call and answers from `handler`.
public final class FakeServer: @unchecked Sendable {
    public let host = "stub-\(UUID().uuidString.lowercased()).test"
    public var baseURL: URL { URL(string: "https://\(host)")! }
    private let lock = NSLock()
    private var recorded: [StubProtocol.Call] = []
    public var handler: (StubProtocol.Call) -> StubProtocol.Reply = { _ in .offline }

    public init() {
        StubProtocol.register(host: host) { [unowned self] call in
            self.lock.lock(); self.recorded.append(call); self.lock.unlock()
            return self.handler(call)
        }
    }

    public var calls: [StubProtocol.Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    public var actions: [String] { calls.map(\.action) }

    public lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()
}

/// Signs tokens the way the server does, with the published throwaway test keys.
public enum TestKeys {
    // From tests/vectors/license-token-v1.json: TEST KEYS ONLY.
    public static let seeds = [
        "k-test-1": "mpZYGxpSo79bCr+O9bl88ij3nsGHghlEhLZBVGl1toc=",
        "k-test-2": "8IcDKAFP3zBH/KCp7FxPZyD/LiN4kvrY4Opthyq/hqw=",
        "k-test-9": "llqL0IjPcgfSHx4KoH3BDAqaZWokcQdnQTOelFKUCu0=",
    ]
    public static let trusted = [
        "k-test-1": "MwhKI3s/ZgWNKaAhSHr9JM8YjI5bEuFREV5QcIWDJiY=",
        "k-test-2": "MHTLL2mbYkq6vfQO/O9AEAMtLeEseiyWCb5sOq+ZDGc=",
    ]

    public static func token(
        kid: String = "k-test-1",
        signWith: String? = nil,
        typ: String = "license",
        key: String,
        storeID: Int = 100200,
        productID: Int = 4100105,
        variantID: Int = 5100105,
        instanceID: String?,
        iat: Date = Date(timeIntervalSince1970: 1_796_126_400),
        exp: Date? = nil,
        reason: String? = nil
    ) -> String {
        func q(_ s: String) -> String { "\"\(s)\"" }
        var json = "{\"v\":1,\"kid\":\(q(kid)),\"typ\":\(q(typ)),\"key_hash\":\(q(LicenseKeyHash.hash(key)))"
        json += ",\"store_id\":\(storeID),\"product_id\":\(productID),\"variant_id\":\(variantID)"
        json += ",\"instance_id\":\(instanceID.map(q) ?? "null"),\"iat\":\(Int(iat.timeIntervalSince1970))"
        json += ",\"exp\":\(exp.map { String(Int($0.timeIntervalSince1970)) } ?? "null")"
        if let reason { json += ",\"reason\":\(q(reason))" }
        json += "}"
        let signingInput = "v1." + b64url(Data(json.utf8))
        // CryptoKit's Ed25519 signatures are randomised, so the same payload
        // signs differently each time. Tests compare stored tokens: memoise.
        let cacheKey = (signWith ?? kid) + "|" + signingInput
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[cacheKey] { return cached }
        let seed = Data(base64Encoded: seeds[signWith ?? kid]!)!
        let privateKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signature = try! privateKey.signature(for: Data(signingInput.utf8))
        let token = signingInput + "." + b64url(signature)
        cache[cacheKey] = token
        return token
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]
}

/// A clock a test can move.
public final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    public init(_ iso: String = "2026-12-02T00:00:00Z") { value = ISO8601DateFormatter().date(from: iso)! }
    public var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    public func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
