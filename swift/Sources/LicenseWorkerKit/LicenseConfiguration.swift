import Foundation

public struct LicenseConfiguration: Sendable {
    /// The server root; the client appends `/v1/licenses/<action>`.
    public var baseURL: URL
    /// kid -> raw Ed25519 public key, base64: both keys your server publishes
    /// (active and backup). A token signed by any other key is rejected.
    public var publicKeys: [String: String]
    /// What a licence must be for. nil = not checked.
    public var storeID: Int?
    public var productIDs: [Int]?
    public var variantIDs: [Int]?
    /// How long past `exp` a signed licence still opens the app.
    public var graceSeconds: TimeInterval
    /// Online validation happens at most this often while the licence is in order.
    public var validationInterval: TimeInterval
    /// After an attempt that got no usable answer, the next one waits this long
    /// within one run of the app. A new launch always tries again.
    public var retryInterval: TimeInterval
    public var requestTimeout: TimeInterval

    public init(
        baseURL: URL,
        publicKeys: [String: String],
        storeID: Int? = nil,
        productIDs: [Int]? = nil,
        variantIDs: [Int]? = nil,
        graceSeconds: TimeInterval = LicenseTokenVerifier.defaultGraceSeconds,
        validationInterval: TimeInterval = 24 * 3600,
        retryInterval: TimeInterval = 15 * 60,
        requestTimeout: TimeInterval = 15
    ) {
        self.baseURL = baseURL
        self.publicKeys = publicKeys
        self.storeID = storeID
        self.productIDs = productIDs
        self.variantIDs = variantIDs
        self.graceSeconds = graceSeconds
        self.validationInterval = validationInterval
        self.retryInterval = retryInterval
        self.requestTimeout = requestTimeout
    }

    var verifier: LicenseTokenVerifier {
        LicenseTokenVerifier(publicKeys: publicKeys, graceSeconds: graceSeconds)
    }

    func expectation(licenseKey: String, instanceID: String?) -> TokenExpectation {
        TokenExpectation(
            keyHash: LicenseKeyHash.hash(licenseKey),
            storeID: storeID,
            productIDs: productIDs,
            variantIDs: variantIDs,
            instanceID: instanceID
        )
    }
}
