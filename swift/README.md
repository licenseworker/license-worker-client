# LicenseWorkerKit

The License Worker client in Swift, for macOS and iOS apps: activate a key,
check it offline-tolerantly with a signed Ed25519 licence, deactivate. No
dependencies beyond Foundation, CryptoKit and Security. macOS 12+, iOS 15+.

It follows the same rules as the Rust crate and the C interface in this
repository ([`PROTOCOL.md`](../PROTOCOL.md)), and passes the same 16 test
vectors.

## Install

In Xcode: File > Add Package Dependencies, the URL
`https://github.com/licenseworker/license-worker-client`, product
`LicenseWorkerKit`. Or in a `Package.swift`:

```swift
.package(url: "https://github.com/licenseworker/license-worker-client", from: "0.3.0"),
// in the app target:
.product(name: "LicenseWorkerKit", package: "license-worker-client"),
// in its test target, for the scripted server:
.product(name: "LicenseWorkerKitTesting", package: "license-worker-client"),
```

Swift Package Manager fetches Swift sources only: the C interface's
XCFramework is not part of this package.

## Quick start

```swift
import LicenseWorkerKit
import SwiftUI

@MainActor
let licence = LicenseController(
    configuration: LicenseConfiguration(
        baseURL: URL(string: "https://license.example.com")!,
        // Both keys your server publishes (install/public-keys.json): active and backup.
        publicKeys: ["k1": "<active public key, base64>", "k2": "<backup public key, base64>"],
        productIDs: [900000001]
    ),
    storage: KeychainLicenseStorage(service: "com.example.myapp.licence")
)

struct ContentView: View {
    @ObservedObject var licence: LicenseController

    var body: some View {
        Group {
            if licence.status.isUnlocked { MainView() } else { LicenceWindow(licence: licence) }
        }
        .task { await licence.refreshIfDue() } // at launch; call it from a timer too
    }
}

// The licence window:
do {
    try await licence.activate(key: typedKey)
} catch let error as LicenseError {
    show(error) // .keyNotFound, .activationLimitReached, .wrongProduct, .serverUnavailable, ...
}

// "Deactivate this computer":
try await licence.deactivate()
```

`status` is published, so SwiftUI redraws when it changes:

| `LicenseStatus` | Unlocked | Meaning |
|---|---|---|
| `.licensed(.signed)` | yes | A signed licence that verifies |
| `.licensed(.grace)` | yes | Past its expiry, inside the grace period: ask the user to renew |
| `.licensed(.unverified)` | yes | Open on the previous state: an older app version's key not yet confirmed by the server |
| `.unlicensed` | no | No licence |
| `.revoked(reason:)` | no | The server signed a revocation (`disabled`, `refunded`, `expired`) |
| `.expired` | no | A subscription past its grace period |

## What the controller does

| What happened | What the app does |
|---|---|
| A valid signed licence is stored | Opens, whatever the network |
| No answer, a network error, 5xx, 429, a garbled or **unsigned** answer | Stays as it was |
| A **signed** revocation | Locks, and keeps the revocation so the reason shows at the next launch |
| The server does not know the `instance_id` | Activates again, silently |
| A signed licence past its expiry | Validates online; 14 days of grace |
| The clock is set back | Verifies against the latest time it has seen |
| The server grants a seat the app cannot use or store | Gives the seat back, then reports the error |

`refreshIfDue()` asks the server at most once a day (`validationInterval`)
while the licence is in order, and at every launch while it awaits its first
confirmation, is in grace or has expired. After an attempt with no usable
answer it waits `retryInterval` (15 minutes) within one run. `refresh()` asks
now.

## Upgrading from an older app version

An app that already sold licences another way can hand the old state over
once, on the first launch of the new version. The app stays open on it until
the server confirms it with a signed licence; nothing is deleted.

```swift
LicenseController(
    configuration: configuration,
    storage: KeychainLicenseStorage(service: "com.example.myapp.licence"),
    legacy: {
        guard let key = UserDefaults.standard.string(forKey: "licenseKey") else { return nil }
        return LegacyLicense(
            licenseKey: key,
            instanceID: UserDefaults.standard.string(forKey: "instanceID"),
            wasUnlocked: UserDefaults.standard.bool(forKey: "isLicensed")
        )
    }
)
```

## Storage

| Type | Where |
|---|---|
| `KeychainLicenseStorage(service:)` | The Keychain, one generic-password item (macOS and iOS) |
| `FileLicenseStorage(url:)` | A JSON file, e.g. in Application Support |
| `InMemoryLicenseStorage` | Nowhere: tests and previews |

Or conform to `LicenseStorage` (`load`, `save`, `clear`).

## Testing your app

`LicenseWorkerKitTesting` gives a test target a scripted server (`FakeServer`,
no network), a signer with the published throwaway test keys (`TestKeys`) and a
movable clock (`TestClock`). Never link it into the app itself.

```swift
import LicenseWorkerKit
import LicenseWorkerKitTesting

let server = FakeServer()
let clock = TestClock()
let token = TestKeys.token(key: key, productID: 900000001, instanceID: "i-1")
server.handler = { call in
    .json(["activated": true, "error": nil, "instance": ["id": "i-1"], "token": token])
}
let licence = await LicenseController(
    configuration: LicenseConfiguration(baseURL: server.baseURL, publicKeys: TestKeys.trusted, productIDs: [900000001]),
    storage: InMemoryLicenseStorage(),
    session: server.session,
    now: { clock.now }
)
```

This package's own tests (`swift test` at the repository root) cover every
row of the table above from every starting state, the client's requests, the
Keychain, and the shared vectors.

## Only the verifier

```swift
let verdict = LicenseTokenVerifier(publicKeys: keys).verify(
    token,
    expecting: TokenExpectation(keyHash: LicenseKeyHash.hash(key), productIDs: [900000001], instanceID: instanceID),
    now: Date(),
    highWaterMark: latestTimeSeen
)
```
