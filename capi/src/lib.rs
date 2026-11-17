//! The C ABI of license-worker-client, for C and C++ apps and audio plugins
//! (VST3, AU, AAX, CLAP). The header is `capi/include/license_worker.h`,
//! generated from this file by cbindgen (`tests/header.rs` keeps it current).
//!
//! Rules of the interface:
//! - Every function catches Rust panics; none unwinds into C. A caught panic
//!   answers `LW_RESULT_PANIC` (or NULL from a constructor).
//! - Strings in are UTF-8, NUL-terminated, borrowed for the call only.
//! - Strings out are owned by the caller and freed with `lw_string_free`;
//!   an `LwStatus` is cleared with `lw_status_clear`.
//! - NULL is accepted wherever a pointer is optional, and refused with
//!   `LW_RESULT_INVALID_ARGUMENT` wherever it is not.
#![allow(clippy::missing_safety_doc)] // the header documents each function's contract

use license_worker_client::{Error, FileStorage, LicenseClient, Options, Status, Storage, StoredLicence};
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::time::Duration;

/// What a call came to.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LwResult {
    /// Done.
    Ok = 0,
    /// No usable answer from the server: no network, a timeout, a rate limit, a server error.
    Unreachable = 1,
    /// The server refused; the message is the server's (e.g. "license_key not found.").
    Refused = 2,
    /// The server granted a licence this app does not accept (another product, a key it does not embed). The seat was given back.
    NotForThisApp = 3,
    /// The licence could not be stored (file or keyring).
    Storage = 4,
    /// A required pointer was NULL, or a string was not UTF-8, or the config was incomplete.
    InvalidArgument = 5,
    /// A bug inside the library was caught before it reached your code.
    Panic = 6,
}

/// Whether the app should open. Only `unlocked` matters to most apps.
/// Zero is `LW_STATE_INACTIVE`, so a zero-initialised status never reads as licensed.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LwState {
    /// Not activated, or the stored licence is no longer usable (`reason` says why).
    Inactive = 0,
    /// A licence in force.
    Valid = 1,
    /// Expired, inside the grace period: open, and a good moment to ask the user to renew.
    Grace = 2,
    /// The server signed a revocation of this key; the stored licence is forgotten.
    Revoked = 3,
}

/// The answer of a check or an activation. Clear it with `lw_status_clear`.
#[repr(C)]
#[derive(Debug)]
pub struct LwStatus {
    pub state: LwState,
    /// `LW_STATE_VALID` or `LW_STATE_GRACE`: open the app.
    pub unlocked: bool,
    /// The server did not answer; the stored licence decided.
    pub offline: bool,
    /// Whether `expires` holds a date; a perpetual licence has none.
    pub has_expiry: bool,
    /// Expiry, unix seconds, when `has_expiry`.
    pub expires: i64,
    /// Why it is inactive or revoked, or NULL. Owned by the status.
    pub reason: *mut c_char,
}

/// How to create a client. Zero-initialise it (`LwConfig cfg = {0};`), then set what you need:
/// `server_url`, both public keys, and `storage_path` (or `keyring_service`) are required.
#[repr(C)]
#[derive(Debug)]
pub struct LwConfig {
    /// e.g. `"https://license.example.com"`.
    pub server_url: *const c_char,
    /// The kids of the public keys, `key_count` of them, e.g. {"k1", "k2"}.
    pub key_ids: *const *const c_char,
    /// The public keys (base64), in the same order as `key_ids`. Embed both keys your server publishes.
    pub public_keys: *const *const c_char,
    pub key_count: usize,
    /// Accept only licences of these products; none (0) accepts any.
    pub product_ids: *const i64,
    pub product_count: usize,
    /// Accept only licences of these variants; none (0) accepts any.
    pub variant_ids: *const i64,
    pub variant_count: usize,
    /// Shown in the admin page next to the activation; NULL: this computer's name.
    pub instance_name: *const c_char,
    /// Days past expiry a subscription still opens the app; 0: the default (14); negative: none.
    pub grace_days: i32,
    /// Per request, milliseconds; 0: the default (10000).
    pub timeout_ms: u32,
    /// The JSON file that keeps the licence. Used when `keyring_service` is NULL.
    pub storage_path: *const c_char,
    /// With the `keyring` feature: keep the licence in the OS credential store under this service
    /// (e.g. "com.example.myplugin"), account "licence". Without the feature, setting it is an error.
    pub keyring_service: *const c_char,
}

enum AnyStorage {
    File(FileStorage),
    #[cfg(feature = "keyring")]
    Keyring(license_worker_client::KeyringStorage),
}

impl Storage for AnyStorage {
    fn load(&self) -> Option<StoredLicence> {
        match self {
            AnyStorage::File(s) => s.load(),
            #[cfg(feature = "keyring")]
            AnyStorage::Keyring(s) => s.load(),
        }
    }
    fn save(&self, value: Option<&StoredLicence>) -> std::io::Result<()> {
        match self {
            AnyStorage::File(s) => s.save(value),
            #[cfg(feature = "keyring")]
            AnyStorage::Keyring(s) => s.save(value),
        }
    }
}

/// A licence client. Opaque; create with `lw_client_new`, free with `lw_client_free`.
/// One client may be used from any thread, one call at a time.
pub struct LwClient {
    inner: LicenseClient<AnyStorage>,
}

fn to_c(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(ptr::null_mut(), CString::into_raw)
}

fn set_out(out: *mut *mut c_char, s: &str) {
    if !out.is_null() {
        // SAFETY: the caller passed a writable `char **` or NULL.
        unsafe { *out = to_c(s) };
    }
}

/// A borrowed UTF-8 string, `None` for NULL, `Err` when not UTF-8.
unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, ()> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p).to_str().map(Some).map_err(|_| ())
}

unsafe fn ids(p: *const i64, n: usize) -> Option<Vec<i64>> {
    (n > 0 && !p.is_null()).then(|| std::slice::from_raw_parts(p, n).to_vec())
}

fn empty_status() -> LwStatus {
    LwStatus { state: LwState::Inactive, unlocked: false, offline: false, has_expiry: false, expires: 0, reason: ptr::null_mut() }
}

fn to_status(s: &Status) -> LwStatus {
    let (state, offline, expires, reason) = match s {
        Status::Valid { expires, offline } => (LwState::Valid, *offline, *expires, None),
        Status::Grace { expires, offline } => (LwState::Grace, *offline, *expires, None),
        Status::Inactive { reason } => (LwState::Inactive, false, None, reason.as_deref()),
        Status::Revoked { reason } => (LwState::Revoked, false, None, reason.as_deref()),
    };
    LwStatus {
        state,
        unlocked: s.unlocked(),
        offline,
        has_expiry: expires.is_some(),
        expires: expires.unwrap_or(0),
        reason: reason.map_or(ptr::null_mut(), to_c),
    }
}

fn error_result(e: &Error) -> LwResult {
    match e {
        Error::Unreachable => LwResult::Unreachable,
        Error::Refused(_) => LwResult::Refused,
        Error::NotForThisApp(_) => LwResult::NotForThisApp,
        Error::Storage(_) => LwResult::Storage,
        _ => LwResult::Refused,
    }
}

fn guard(f: impl FnOnce() -> LwResult) -> LwResult {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(LwResult::Panic)
}

unsafe fn build(cfg: &LwConfig) -> Result<LwClient, &'static str> {
    let bad = "a string in LwConfig is not UTF-8";
    let server_url = opt_str(cfg.server_url).map_err(|_| bad)?.filter(|s| !s.is_empty()).ok_or("server_url is required")?;
    if cfg.key_count == 0 || cfg.key_ids.is_null() || cfg.public_keys.is_null() {
        return Err("public keys are required: embed both keys your server publishes");
    }
    let mut public_keys = HashMap::new();
    for i in 0..cfg.key_count {
        let kid = opt_str(*cfg.key_ids.add(i)).map_err(|_| bad)?.ok_or("a key id is NULL")?;
        let key = opt_str(*cfg.public_keys.add(i)).map_err(|_| bad)?.ok_or("a public key is NULL")?;
        public_keys.insert(kid.to_string(), key.to_string());
    }
    let storage = match opt_str(cfg.keyring_service).map_err(|_| bad)? {
        #[cfg(feature = "keyring")]
        Some(service) => AnyStorage::Keyring(license_worker_client::KeyringStorage::new(service, "licence")),
        #[cfg(not(feature = "keyring"))]
        Some(_) => return Err("keyring_service needs the library built with the keyring feature"),
        None => AnyStorage::File(FileStorage::new(opt_str(cfg.storage_path).map_err(|_| bad)?.ok_or("storage_path or keyring_service is required")?)),
    };
    let mut o = Options {
        server_url: server_url.to_string(),
        public_keys,
        product_ids: ids(cfg.product_ids, cfg.product_count),
        variant_ids: ids(cfg.variant_ids, cfg.variant_count),
        ..Default::default()
    };
    if let Some(name) = opt_str(cfg.instance_name).map_err(|_| bad)? {
        o.instance_name = name.to_string();
    }
    if cfg.grace_days != 0 {
        o.grace_days = i64::from(cfg.grace_days.max(0));
    }
    if cfg.timeout_ms != 0 {
        o.timeout = Duration::from_millis(u64::from(cfg.timeout_ms));
    }
    Ok(LwClient { inner: LicenseClient::new(o, storage) })
}

/// Creates a client. Makes no request. Returns NULL on failure, with a message in `*error`
/// (when `error` is not NULL; free it with `lw_string_free`).
#[no_mangle]
pub unsafe extern "C" fn lw_client_new(config: *const LwConfig, error: *mut *mut c_char) -> *mut LwClient {
    if !error.is_null() {
        *error = ptr::null_mut();
    }
    let r = catch_unwind(AssertUnwindSafe(|| {
        if config.is_null() {
            return Err("config is NULL");
        }
        build(&*config)
    }));
    match r {
        Ok(Ok(c)) => Box::into_raw(Box::new(c)),
        Ok(Err(m)) => {
            set_out(error, m);
            ptr::null_mut()
        }
        Err(_) => {
            set_out(error, "internal error");
            ptr::null_mut()
        }
    }
}

/// Frees a client. NULL is ignored.
#[no_mangle]
pub unsafe extern "C" fn lw_client_free(client: *mut LwClient) {
    if !client.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(client))));
    }
}

/// From the licence window: activates `key` on this computer and stores the licence.
/// On `LW_RESULT_OK`, `*status` is filled. Otherwise nothing stored changes, and `*message`
/// (when not NULL) is a sentence to show the user. Blocks on the network: not on an audio or UI thread.
#[no_mangle]
pub unsafe extern "C" fn lw_activate(client: *const LwClient, key: *const c_char, status: *mut LwStatus, message: *mut *mut c_char) -> LwResult {
    if !message.is_null() {
        *message = ptr::null_mut();
    }
    if !status.is_null() {
        ptr::write(status, empty_status());
    }
    guard(|| {
        let (Some(c), Ok(Some(key))) = (client.as_ref(), opt_str(key)) else { return LwResult::InvalidArgument };
        match c.inner.activate(key) {
            Ok(s) => {
                if !status.is_null() {
                    ptr::write(status, to_status(&s));
                }
                LwResult::Ok
            }
            Err(e) => {
                set_out(message, &e.to_string());
                error_result(&e)
            }
        }
    })
}

/// At start-up and a few times a day at most: validates online, or judges by the stored licence
/// when the server does not answer. Only a signed revocation locks. Fills `*status`.
/// Blocks on the network: not on an audio or UI thread.
#[no_mangle]
pub unsafe extern "C" fn lw_check(client: *const LwClient, status: *mut LwStatus) -> LwResult {
    if status.is_null() {
        return LwResult::InvalidArgument;
    }
    ptr::write(status, empty_status());
    guard(|| {
        let Some(c) = client.as_ref() else { return LwResult::InvalidArgument };
        ptr::write(status, to_status(&c.inner.check()));
        LwResult::Ok
    })
}

/// Judges the stored licence with no request: fast, for start-up before `lw_check` has answered.
#[no_mangle]
pub unsafe extern "C" fn lw_check_offline(client: *const LwClient, status: *mut LwStatus) -> LwResult {
    if status.is_null() {
        return LwResult::InvalidArgument;
    }
    ptr::write(status, empty_status());
    guard(|| {
        let Some(c) = client.as_ref() else { return LwResult::InvalidArgument };
        ptr::write(status, to_status(&c.inner.check_offline()));
        LwResult::Ok
    })
}

/// "Deactivate this computer": frees the seat, and forgets the licence once the server confirmed.
/// On failure `*message` (when not NULL) is a sentence to show the user.
#[no_mangle]
pub unsafe extern "C" fn lw_deactivate(client: *const LwClient, message: *mut *mut c_char) -> LwResult {
    if !message.is_null() {
        *message = ptr::null_mut();
    }
    guard(|| {
        let Some(c) = client.as_ref() else { return LwResult::InvalidArgument };
        match c.inner.deactivate() {
            Ok(()) => LwResult::Ok,
            Err(e) => {
                set_out(message, &e.to_string());
                error_result(&e)
            }
        }
    })
}

/// Frees the strings a status owns and resets it. Safe to call twice; NULL is ignored.
#[no_mangle]
pub unsafe extern "C" fn lw_status_clear(status: *mut LwStatus) {
    if !status.is_null() {
        // Only the pointer field is read: the rest may hold anything the caller left there.
        lw_string_free(ptr::addr_of!((*status).reason).read());
        ptr::write(status, empty_status());
    }
}

/// Frees a string the library returned. NULL is ignored.
#[no_mangle]
pub unsafe extern "C" fn lw_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// This computer's name (the default instance name). Free with `lw_string_free`.
#[no_mangle]
pub extern "C" fn lw_default_instance_name() -> *mut c_char {
    catch_unwind(license_worker_client::default_instance_name).map_or(ptr::null_mut(), |s| to_c(&s))
}

/// The library's version, e.g. "0.1.0". Static: do not free.
#[no_mangle]
pub extern "C" fn lw_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// A short English name of an `LwResult` value, e.g. "unreachable" (or "unknown"). Static: do not free.
#[no_mangle]
pub extern "C" fn lw_result_name(result: i32) -> *const c_char {
    let s: &'static str = match result {
        0 => "ok\0",
        1 => "unreachable\0",
        2 => "refused\0",
        3 => "not_for_this_app\0",
        4 => "storage\0",
        5 => "invalid_argument\0",
        6 => "panic\0",
        _ => "unknown\0",
    };
    s.as_ptr().cast()
}
