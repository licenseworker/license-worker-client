//! The offline half: checks a signed licence `v1.<payload>.<signature>` with
//! the server's Ed25519 public keys, without any network.
//!
//! ```
//! use license_worker_client::verify::{verify, Expect, Options, Verified};
//! # use std::collections::HashMap;
//! # let (token, keys, now) = (String::new(), HashMap::new(), 0);
//! let r = verify(&token, &keys, now, &Expect::default(), Options::default());
//! if matches!(r, Ok(Verified::Valid(_)) | Ok(Verified::Grace(_))) { /* unlock */ }
//! ```
//!
//! Only [`Verified::Revoked`] should ever lock an app; every `Err` leaves it as it was.
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fmt;

/// The signed fields of a licence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Payload {
    pub v: u32,
    /// Which of the server's keys signed it.
    pub kid: String,
    /// `"license"` or `"revoked"`.
    pub typ: String,
    /// sha256 hex of the normalised licence key (see [`key_hash`]).
    pub key_hash: String,
    pub store_id: i64,
    pub product_id: i64,
    pub variant_id: i64,
    pub instance_id: Option<String>,
    /// Issued at, unix seconds.
    pub iat: i64,
    /// Expires at, unix seconds; `None` is perpetual.
    pub exp: Option<i64>,
    /// Why it was revoked, on a revocation.
    #[serde(default)]
    pub reason: Option<String>,
}

/// A licence whose signature and fields check out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verified {
    /// Before `exp`, or perpetual.
    Valid(Payload),
    /// Past `exp`, within the grace period.
    Grace(Payload),
    /// A signed revocation of this key: the one answer that locks.
    Revoked(Payload),
}

impl Verified {
    pub fn payload(&self) -> &Payload {
        match self {
            Verified::Valid(p) | Verified::Grace(p) | Verified::Revoked(p) => p,
        }
    }
}

/// Why a licence was not accepted. None of these is a reason to lock an app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Failure {
    Malformed,
    UnsupportedVersion,
    UnknownKid,
    BadSignature,
    WrongKey,
    WrongProduct,
    WrongInstance,
    Expired,
}

impl Failure {
    /// The name the shared test vectors use, e.g. `"bad_signature"`.
    pub fn as_str(self) -> &'static str {
        match self {
            Failure::Malformed => "malformed",
            Failure::UnsupportedVersion => "unsupported_version",
            Failure::UnknownKid => "unknown_kid",
            Failure::BadSignature => "bad_signature",
            Failure::WrongKey => "wrong_key",
            Failure::WrongProduct => "wrong_product",
            Failure::WrongInstance => "wrong_instance",
            Failure::Expired => "expired",
        }
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Failure {}

/// What the licence must be about. `None` fields are not checked.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Expect {
    pub key_hash: Option<String>,
    pub product_ids: Option<Vec<i64>>,
    pub variant_ids: Option<Vec<i64>>,
    pub instance_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    /// How long past `exp` the licence still opens the app.
    pub grace_seconds: i64,
    /// The latest time (unix seconds) this device has ever seen; setting the clock back cannot go below it.
    pub high_water_mark: Option<i64>,
}

impl Default for Options {
    fn default() -> Self {
        Options { grace_seconds: 14 * 24 * 3600, high_water_mark: None }
    }
}

/// sha256 hex of the key with all whitespace removed, lowercased: what `key_hash` must equal.
pub fn key_hash(licence_key: &str) -> String {
    let norm: String = licence_key.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_lowercase();
    Sha256::digest(norm.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

/// Verifies `token` against `public_keys` (kid -> raw 32-byte Ed25519 public key, base64).
/// Embed both keys your server publishes, so a key rotation does not lock anyone out.
pub fn verify(token: &str, public_keys: &HashMap<String, String>, now_unix: i64, expect: &Expect, opts: Options) -> Result<Verified, Failure> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return Err(Failure::Malformed);
    }
    if parts[0] != "v1" {
        return Err(Failure::UnsupportedVersion);
    }
    let body = URL_SAFE_NO_PAD.decode(parts[1]).map_err(|_| Failure::Malformed)?;
    let sig = URL_SAFE_NO_PAD.decode(parts[2]).map_err(|_| Failure::Malformed)?;
    let p: Payload = serde_json::from_slice(&body).map_err(|_| Failure::Malformed)?;
    if p.typ != "license" && p.typ != "revoked" {
        return Err(Failure::Malformed);
    }
    if p.v != 1 {
        return Err(Failure::UnsupportedVersion);
    }
    let sig: [u8; 64] = sig.try_into().map_err(|_| Failure::BadSignature)?;
    // `kid` only chooses which embedded key to try; nothing else is trusted yet.
    let pub64 = public_keys.get(&p.kid).ok_or(Failure::UnknownKid)?;
    let raw: [u8; 32] = STANDARD.decode(pub64).ok().and_then(|r| r.try_into().ok()).ok_or(Failure::BadSignature)?;
    let key = VerifyingKey::from_bytes(&raw).map_err(|_| Failure::BadSignature)?;
    let signing_input = format!("{}.{}", parts[0], parts[1]);
    key.verify(signing_input.as_bytes(), &Signature::from_bytes(&sig)).map_err(|_| Failure::BadSignature)?;

    if expect.key_hash.as_ref().is_some_and(|h| *h != p.key_hash) {
        return Err(Failure::WrongKey);
    }
    if expect.product_ids.as_ref().is_some_and(|ids| !ids.contains(&p.product_id)) {
        return Err(Failure::WrongProduct);
    }
    if expect.variant_ids.as_ref().is_some_and(|ids| !ids.contains(&p.variant_id)) {
        return Err(Failure::WrongProduct);
    }
    if p.typ == "revoked" {
        // About the key, whatever the instance.
        return Ok(Verified::Revoked(p));
    }
    if let Some(id) = &expect.instance_id {
        if p.instance_id.as_deref() != Some(id.as_str()) {
            return Err(Failure::WrongInstance);
        }
    }
    let Some(exp) = p.exp else { return Ok(Verified::Valid(p)) };
    let now = opts.high_water_mark.map_or(now_unix, |h| now_unix.max(h));
    if now <= exp {
        Ok(Verified::Valid(p))
    } else if now <= exp + opts.grace_seconds {
        Ok(Verified::Grace(p))
    } else {
        Err(Failure::Expired)
    }
}
