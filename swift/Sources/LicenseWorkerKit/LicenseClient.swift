import Foundation

/// One answer of the licence server, in Lemon Squeezy's shape plus `token`.
/// Every field is optional: the failure bodies carry only a flag and an error,
/// and a missing field (422) carries `message` and no flag at all.
public struct LicenseResponse: Equatable, Sendable {
    public var activated: Bool?
    public var valid: Bool?
    public var deactivated: Bool?
    public var error: String?
    public var licenseStatus: String?
    public var activationLimit: Int?
    public var activationUsage: Int?
    public var instanceID: String?
    public var storeID: Int?
    public var productID: Int?
    public var variantID: Int?
    /// The signed licence. Absent or null on an unsigned answer.
    public var token: String?

    init(json: [String: Any]) {
        activated = json["activated"] as? Bool
        valid = json["valid"] as? Bool
        deactivated = json["deactivated"] as? Bool
        // Laravel's validation shape puts the text in `message`.
        error = (json["error"] as? String) ?? (json["message"] as? String)
        if let key = json["license_key"] as? [String: Any] {
            licenseStatus = key["status"] as? String
            activationLimit = key["activation_limit"] as? Int
            activationUsage = key["activation_usage"] as? Int
        }
        if let instance = json["instance"] as? [String: Any] {
            instanceID = instance["id"] as? String
        }
        if let meta = json["meta"] as? [String: Any] {
            storeID = meta["store_id"] as? Int
            productID = meta["product_id"] as? Int
            variantID = meta["variant_id"] as? Int
        }
        token = json["token"] as? String
    }
}

/// What came back from one request.
public enum ServerAnswer: Equatable, Sendable {
    /// The server said something definite: a JSON object, on a status that is
    /// neither 429 nor 5xx. Whether it may change anything is decided by the
    /// signature, not here.
    case answered(LicenseResponse, status: Int)
    /// Nothing usable: no connection, a timeout, 429, 5xx, or a body that is
    /// not a JSON object. The app stays exactly as it was.
    case unavailable(Unavailability)

    public enum Unavailability: Equatable, Sendable {
        case network(String)
        case rateLimited
        case serverError(Int)
        case garbled
    }
}

/// The server's error strings the client acts on. They are Lemon Squeezy's,
/// which License Worker sends word for word (PROTOCOL.md).
public enum ServerErrorText {
    public static let instanceNotFound = "instance_id not found."
    public static let keyNotFound = "license_key not found."
    public static let activationLimit = "This license key has reached the activation limit."

    static func matches(_ error: String?, _ expected: String) -> Bool {
        guard let error else { return false }
        return error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected.lowercased()
    }
}

/// HTTP client for `activate`, `validate` and `deactivate`. Requests are
/// form-urlencoded with `Accept: application/json` and carry no credentials.
public struct LicenseClient: Sendable {
    public let baseURL: URL
    public let session: URLSession
    public let timeout: TimeInterval

    public init(baseURL: URL, session: URLSession? = nil, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func activate(licenseKey: String, instanceName: String) async -> ServerAnswer {
        await post("activate", ["license_key": licenseKey, "instance_name": instanceName])
    }

    public func validate(licenseKey: String, instanceID: String?) async -> ServerAnswer {
        var form = ["license_key": licenseKey]
        if let instanceID { form["instance_id"] = instanceID }
        return await post("validate", form)
    }

    public func deactivate(licenseKey: String, instanceID: String) async -> ServerAnswer {
        await post("deactivate", ["license_key": licenseKey, "instance_id": instanceID])
    }

    func post(_ action: String, _ form: [String: String]) async -> ServerAnswer {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/licenses/\(action)"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unavailable(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { return .unavailable(.garbled) }
        if http.statusCode == 429 { return .unavailable(.rateLimited) }
        if http.statusCode >= 500 { return .unavailable(.serverError(http.statusCode)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable(.garbled)
        }
        return .answered(LicenseResponse(json: json), status: http.statusCode)
    }

    static func formEncode(_ form: [String: String]) -> Data {
        // RFC 3986 unreserved characters; everything else is percent-encoded.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.sorted { $0.key < $1.key }.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
