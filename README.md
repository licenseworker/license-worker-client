# license-worker-client

A Rust client for [License Worker](https://github.com/licenseworker), the
self-hosted licence server: activate a key, check it at start-up, deactivate.
It keeps the app open when the server or the network fails, judging by a
signed Ed25519 licence stored on the device.

For desktop apps on **Windows**, macOS and Linux, and for the Rust side of a
**Tauri** app. Blocking (`ureq` 2), no async runtime. MIT.

```sh
cargo add license-worker-client --features keyring
```

On [crates.io](https://crates.io/crates/license-worker-client), with the API
documentation on [docs.rs](https://docs.rs/license-worker-client).

## Quick start

```rust
use license_worker_client::{KeyringStorage, LicenseClient, Options};
use std::collections::HashMap;

let client = LicenseClient::new(
    Options {
        server_url: "https://license.example.com".into(),
        // Both keys from your server's install/public-keys.json.
        public_keys: HashMap::from([
            ("k1".into(), "<active public key, base64>".into()),
            ("k2".into(), "<backup public key, base64>".into()),
        ]),
        product_ids: Some(vec![900000001]),
        ..Default::default() // instance_name: this computer's name; 14 days' grace; 10 s timeout
    },
    KeyringStorage::new("com.example.myapp", "licence"),
);

// The licence window:
match client.activate(&key_from_user) {
    Ok(status) => println!("activated: {status:?}"),
    Err(e) => show_message(&e.to_string()), // the server's message, or a plain one
}

// At start-up, and a few times a day at most:
if client.check().unlocked() {
    open_the_app();
}

// "Deactivate this computer":
client.deactivate()?;
```

`check()` answers a `Status`:

| Status | `unlocked()` | Meaning |
|---|---|---|
| `Valid { expires, offline }` | yes | A licence in force. `offline`: the server did not answer, the stored licence decided. |
| `Grace { expires, offline }` | yes | Expired, inside the grace period. A good moment to ask the user to renew. |
| `Inactive { reason }` | no | Not activated, or the stored licence is no longer usable (`expired`, `wrong_product`, …). |
| `Revoked { reason }` | no | The server signed a revocation of this key. The stored licence is forgotten. |

`check_offline()` judges the stored licence with no request, for an instant
start-up screen before `check()` has answered.

### Storage

| Type | Where |
|---|---|
| `KeyringStorage` (feature `keyring`) | Windows Credential Manager, macOS Keychain, Linux Secret Service (GNOME Keyring, KWallet) |
| `FileStorage` | A JSON file you name, e.g. in the app's data folder |
| `MemoryStorage` | Nowhere: tests |

Or implement `Storage` (two methods, `load` and `save`) for anything else.
On Linux the `keyring` feature needs `libdbus-1-dev` and `pkg-config` to build,
and a running Secret Service to work.

`default_instance_name()` is the computer's name, the default
`instance_name`: you will see it in the admin page next to the activation.

### HTTPS

On Windows the client uses Windows' own TLS (schannel), so it trusts the
Windows certificate store, company proxies included, and builds with no C
toolchain. Elsewhere it uses rustls with the webpki roots, so Linux needs no
OpenSSL. `UreqTransport::with_agent` takes a `ureq::Agent` you configured
(proxy, timeouts).

## The client rules

The crate follows these, so your app does not have to. They are why a
customer who paid is never locked out by a bad minute on the server.

1. **Only a signed revocation locks.** When the server answers with a token
   whose `typ` is `revoked`, signed by one of your keys, the app locks and the
   stored licence is forgotten. Nothing else locks: not a timeout, not a 429,
   not a 5xx, not `valid: false` without a token, not `license_key not found.`
   They leave the app as it was.
2. **When offline, judge by the stored token.** The client keeps the key, the
   instance id and the last signed licence. With no usable answer it verifies
   the stored one: a perpetual licence stays valid indefinitely, a
   subscription until its expiry and then through the grace period.
3. **The high-water clock.** The client stores the latest time the device has
   seen and verifies against `max(now, that)`, so setting the clock back
   cannot stretch an expired licence.
4. **Embed both public keys.** Your server publishes two, active and backup.
   Embed both; the token's `kid` chooses. The server can then move to the
   backup key without an app release. An app with only one rejects every
   licence after a rotation.
5. **Re-activate quietly on `instance_id not found.`** The activation was
   released (by the customer, by you in the admin page, or in a migration).
   `check()` takes a new one with the same key and carries on; nothing is shown
   unless that fails too.
6. **Give the seat back when the app refuses a licence.** If the server grants
   an activation the app cannot use (another product, a key the app does not
   embed, or it cannot be stored), `activate` deactivates it again before
   returning the error, so the customer does not lose a seat.

## Tauri

Every call blocks on the network for up to a few timeouts, so run it on
Tauri's blocking pool, never on the main thread. `Status` serialises to JSON
for the frontend (`{"state": "valid", "expires": null, "offline": false}`).

```rust
use license_worker_client::{KeyringStorage, LicenseClient, Options, Status};
use std::sync::Arc;

type Client = Arc<LicenseClient<KeyringStorage>>;

#[tauri::command]
async fn licence_check(client: tauri::State<'_, Client>) -> Result<Status, String> {
    let client = client.inner().clone();
    tauri::async_runtime::spawn_blocking(move || client.check()).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn licence_activate(key: String, client: tauri::State<'_, Client>) -> Result<Status, String> {
    let client = client.inner().clone();
    tauri::async_runtime::spawn_blocking(move || client.activate(&key))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string()) // a message to show the user
}

#[tauri::command]
async fn licence_deactivate(client: tauri::State<'_, Client>) -> Result<(), String> {
    let client = client.inner().clone();
    tauri::async_runtime::spawn_blocking(move || client.deactivate())
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())
}

fn main() {
    let client: Client = Arc::new(LicenseClient::new(
        Options { server_url: "https://license.example.com".into(), /* keys, product ids */ ..Default::default() },
        KeyringStorage::new("com.example.myapp", "licence"),
    ));
    tauri::Builder::default()
        .manage(client)
        .invoke_handler(tauri::generate_handler![licence_check, licence_activate, licence_deactivate])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

`LicenseClient` is `Send + Sync` with the storages here, so one `Arc` serves
every command.

## Swift (macOS and iOS)

[LicenseWorkerKit](swift/README.md) is the same client written in Swift, with
no dependencies beyond Foundation, CryptoKit and Security: a `LicenseController`
state machine (an `ObservableObject` for SwiftUI) over the same rules, Keychain
storage, and a testing library with a scripted server. Add this repository with
Swift Package Manager and `import LicenseWorkerKit`. macOS 12+, iOS 15+.

## C and C++ (audio plugins)

[`capi/`](capi/README.md) is a C interface over the same client, with a
cbindgen header (`capi/include/license_worker.h`), opaque handles and no
panics across the boundary, for C++ apps and VST3, AU, AAX and CLAP plugins.
Plugins link it **statically**. It builds for Windows x64 and ARM64 (MSVC,
static CRT supported), as a universal macOS library, and as one XCFramework
for iOS, the iOS Simulator and macOS. Prebuilt packages for every platform are on each
[GitHub Release](https://github.com/licenseworker/license-worker-client/releases);
the C example passes the same end-to-end check as the Rust client.

## The protocol

[`PROTOCOL.md`](PROTOCOL.md) describes what a server must answer and how a
signed licence is checked. License Worker is the reference server, but any
server that follows it works with this client, and any client that follows it
works with License Worker.

## Only the verifier

`license_worker_client::verify` checks a signed licence with no network and no
state, for an app that does its own HTTP:

```rust
use license_worker_client::verify::{key_hash, verify, Expect, Options, Verified};

let expect = Expect { key_hash: Some(key_hash(&key)), product_ids: Some(vec![900000001]), instance_id: Some(instance_id), ..Default::default() };
match verify(&token, &public_keys, now_unix, &expect, Options { high_water_mark: Some(high_water), ..Default::default() }) {
    Ok(Verified::Valid(_) | Verified::Grace(_)) => unlock(),
    Ok(Verified::Revoked(_)) => lock_and_forget(),
    Err(_) => { /* not a reason to lock: keep the previous state */ }
}
```

## Testing your app offline

`LicenseClient::with_transport` takes any `Transport`, so your tests can
script the server (activate, validate, deactivate answers) and run with no
network; `with_clock` sets the time. This crate's own tests do exactly that
(`tests/client.rs`), and check the verifier against License Worker's 16 shared
test vectors (`tests/vectors.rs`).

```sh
cargo test
cargo test --features keyring
```

The `license-worker-client` binary is the client as a command, the contract
License Worker's end-to-end check drives against a real local server:

```sh
# in the license-worker repository
LW_RUST_CLIENT_DIR=../license-worker-client npm run check:clients
```

## Security

Please report a security problem privately: see [SECURITY.md](SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE).
