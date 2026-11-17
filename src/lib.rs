//! A client for [License Worker](https://github.com/licenseworker) licence
//! servers: activate a key, check it at start-up (offline-tolerantly, from a
//! signed Ed25519 licence), deactivate. Blocking, for desktop apps on
//! Windows, macOS and Linux, and for a Tauri app's Rust side.
//!
//! ```no_run
//! use license_worker_client::{FileStorage, LicenseClient, Options};
//! use std::collections::HashMap;
//!
//! let client = LicenseClient::new(
//!     Options {
//!         server_url: "https://license.example.com".into(),
//!         public_keys: HashMap::from([
//!             ("k1".into(), "<current public key, base64>".into()),
//!             ("k2".into(), "<next public key, base64>".into()),
//!         ]),
//!         product_ids: Some(vec![900000001]),
//!         ..Default::default()
//!     },
//!     FileStorage::new("licence.json"),
//! );
//! client.activate("38B1460A-5104-4067-A91D-77B872934D51")?; // from the licence window
//! if client.check().unlocked() { /* open the app */ }
//! # Ok::<(), license_worker_client::Error>(())
//! ```
//!
//! The rule that matters most: only a **signed** revocation locks. No answer,
//! a rate limit, a 5xx, an unsigned refusal: the app stays as it was, judged
//! by the licence it already holds.
#![forbid(unsafe_code)]

mod client;
pub mod storage;
pub mod transport;
pub mod verify;

pub use client::{Error, LicenseClient, Options, Status};
#[cfg(feature = "keyring")]
pub use storage::KeyringStorage;
pub use storage::{default_instance_name, FileStorage, MemoryStorage, Storage, StoredLicence};
pub use transport::{HttpResponse, Transport, TransportError, UreqTransport};
pub use verify::{key_hash, Failure, Payload, Verified};
