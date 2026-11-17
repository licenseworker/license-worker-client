use crate::storage::{Storage, StoredLicence};
use crate::transport::{Transport, UreqTransport};
use crate::verify::{self, key_hash, Expect, Failure, Verified};
use serde::Serialize;
use std::collections::HashMap;
use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The server's message when it no longer knows an activation.
const INSTANCE_NOT_FOUND: &str = "instance_id not found.";

#[derive(Debug, Clone)]
pub struct Options {
    /// The server's address, e.g. `"https://license.example.com"`.
    pub server_url: String,
    /// Both public keys your server publishes, kid -> base64. Embed both, so a rotation does not lock anyone out.
    pub public_keys: HashMap<String, String>,
    /// Accept only licences of these products (`None`: any).
    pub product_ids: Option<Vec<i64>>,
    /// Accept only licences of these variants (`None`: any).
    pub variant_ids: Option<Vec<i64>>,
    /// Shown in the admin page next to the activation. [`crate::default_instance_name`] is a good choice.
    pub instance_name: String,
    /// How long past its expiry a subscription still opens the app.
    pub grace_days: i64,
    /// Per request.
    pub timeout: Duration,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            server_url: String::new(),
            public_keys: HashMap::new(),
            product_ids: None,
            variant_ids: None,
            instance_name: crate::default_instance_name(),
            grace_days: 14,
            timeout: Duration::from_secs(10),
        }
    }
}

/// Whether the app should open. Only [`Status::unlocked`] matters to most apps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum Status {
    /// A licence in force. `offline`: judged from the stored licence, the server did not answer.
    Valid { expires: Option<i64>, offline: bool },
    /// Expired, inside the grace period: open, and a good moment to ask the user to renew.
    Grace { expires: Option<i64>, offline: bool },
    /// Not activated, or the stored licence is no longer usable (`reason` says why).
    Inactive { reason: Option<String> },
    /// The server signed a revocation of this key. The stored licence is forgotten.
    Revoked { reason: Option<String> },
}

impl Status {
    pub fn unlocked(&self) -> bool {
        matches!(self, Status::Valid { .. } | Status::Grace { .. })
    }
}

/// Why [`LicenseClient::activate`] or [`LicenseClient::deactivate`] did not succeed.
/// `Display` is a message fit to show the user.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// No usable answer: no network, a timeout, a rate limit, a server error.
    Unreachable,
    /// The server refused, with its message (e.g. `"license_key not found."`).
    Refused(String),
    /// The server activated the key, but its licence is not one this app accepts
    /// (another product, or signed with a key the app does not embed). The seat was given back.
    NotForThisApp(Failure),
    /// The licence could not be stored.
    Storage(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Unreachable => f.write_str("The licence server could not be reached. Check the connection and try again."),
            Error::Refused(m) => f.write_str(m),
            Error::NotForThisApp(_) => f.write_str("This key is not for this app."),
            Error::Storage(e) => write!(f, "The licence could not be saved on this computer: {e}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::NotForThisApp(f) => Some(f),
            Error::Storage(e) => Some(e),
            _ => None,
        }
    }
}

struct Answer {
    status: u16,
    body: serde_json::Value,
}

impl Answer {
    fn error(&self) -> Option<&str> {
        self.body.get("error").and_then(|e| e.as_str())
    }
    fn token(&self) -> Option<String> {
        self.body.get("token").and_then(|t| t.as_str()).map(String::from)
    }
    fn instance_id(&self) -> Option<String> {
        self.body.get("instance").and_then(|i| i.get("id")).and_then(|i| i.as_str()).map(String::from)
    }
    fn flag(&self, name: &str) -> bool {
        self.body.get(name).and_then(|f| f.as_bool()) == Some(true)
    }
}

fn system_now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Activates, checks and deactivates a licence. Every call blocks on the
/// network for at most a few timeouts: in a UI app call it off the main thread.
pub struct LicenseClient<S: Storage, T: Transport = UreqTransport> {
    o: Options,
    storage: S,
    transport: T,
    clock: fn() -> i64,
}

impl<S: Storage> LicenseClient<S, UreqTransport> {
    pub fn new(o: Options, storage: S) -> Self {
        let transport = UreqTransport::new(o.timeout);
        Self::with_transport(o, storage, transport)
    }
}

impl<S: Storage, T: Transport> LicenseClient<S, T> {
    /// With your own [`Transport`]: a scripted server in tests, or your own HTTP stack.
    pub fn with_transport(o: Options, storage: S, transport: T) -> Self {
        LicenseClient { o, storage, transport, clock: system_now }
    }

    /// Replaces the clock (unix seconds). For tests.
    pub fn with_clock(mut self, clock: fn() -> i64) -> Self {
        self.clock = clock;
        self
    }

    pub fn options(&self) -> &Options {
        &self.o
    }

    pub fn storage(&self) -> &S {
        &self.storage
    }

    /// `None` = no usable answer (network, timeout, 429, 5xx, not JSON): never a reason to change anything.
    fn call(&self, action: &str, fields: &[(&str, &str)]) -> Option<Answer> {
        let url = format!("{}/v1/licenses/{}", self.o.server_url.trim_end_matches('/'), action);
        let resp = self.transport.post_form(&url, fields).ok()?;
        if resp.status == 429 || resp.status >= 500 {
            return None;
        }
        let body: serde_json::Value = serde_json::from_str(&resp.body).ok()?;
        body.is_object().then_some(Answer { status: resp.status, body })
    }

    fn check_token(&self, token: &str, s: &StoredLicence) -> Result<Verified, Failure> {
        let expect = Expect {
            key_hash: Some(key_hash(&s.key)),
            product_ids: self.o.product_ids.clone(),
            variant_ids: self.o.variant_ids.clone(),
            instance_id: Some(s.instance_id.clone()),
        };
        let opts = verify::Options { grace_seconds: self.o.grace_days * 86_400, high_water_mark: Some(s.high_water) };
        verify::verify(token, &self.o.public_keys, (self.clock)(), &expect, opts)
    }

    fn status(r: Result<Verified, Failure>, offline: bool) -> Status {
        match r {
            Ok(Verified::Valid(p)) => Status::Valid { expires: p.exp, offline },
            Ok(Verified::Grace(p)) => Status::Grace { expires: p.exp, offline },
            Ok(Verified::Revoked(p)) => Status::Revoked { reason: p.reason },
            Err(f) => Status::Inactive { reason: Some(f.as_str().to_string()) },
        }
    }

    /// From the licence window. On failure nothing stored changes; show the error's `Display` to the user.
    pub fn activate(&self, raw_key: &str) -> Result<Status, Error> {
        let key = raw_key.trim();
        let a = self.call("activate", &[("license_key", key), ("instance_name", &self.o.instance_name)]).ok_or(Error::Unreachable)?;
        let refused = || Error::Refused(a.error().unwrap_or("This key could not be activated.").to_string());
        let (Some(instance_id), Some(token)) = (a.instance_id(), a.token()) else { return Err(refused()) };
        if !a.flag("activated") {
            return Err(refused());
        }
        let now = (self.clock)();
        let high_water = self.storage.load().map_or(now, |old| old.high_water.max(now));
        let stored = StoredLicence { key: key.to_string(), instance_id, token, high_water };
        let failure = match self.check_token(&stored.token, &stored) {
            r @ Ok(Verified::Valid(_)) | r @ Ok(Verified::Grace(_)) => match self.storage.save(Some(&stored)) {
                Ok(()) => return Ok(Self::status(r, false)),
                Err(e) => Error::Storage(e),
            },
            Ok(Verified::Revoked(p)) => Error::Refused(p.reason.unwrap_or_else(|| "This key has been revoked.".into())),
            Err(f) => Error::NotForThisApp(f),
        };
        // A licence this app cannot use, or cannot keep: give the seat back and refuse.
        let _ = self.call("deactivate", &[("license_key", key), ("instance_id", &stored.instance_id)]);
        Err(failure)
    }

    /// At start-up and from time to time (a few times a day at most).
    ///
    /// Only a signed revocation locks. No answer, a rate limit, a 5xx, an
    /// unsigned refusal: the app is judged by the licence it already holds.
    pub fn check(&self) -> Status {
        let Some(mut s) = self.storage.load() else { return Status::Inactive { reason: None } };
        s.high_water = s.high_water.max((self.clock)());

        let mut v = self.call("validate", &[("license_key", &s.key), ("instance_id", &s.instance_id)]);
        // The server no longer knows this activation (released from the admin page, or moved servers): take a new one, quietly.
        if v.as_ref().is_some_and(|a| a.status == 404 && a.error() == Some(INSTANCE_NOT_FOUND)) {
            let a = self.call("activate", &[("license_key", &s.key), ("instance_name", &self.o.instance_name)]);
            v = match a {
                Some(a) if a.flag("activated") => match a.instance_id() {
                    Some(id) => {
                        s.instance_id = id;
                        Some(a)
                    }
                    None => None,
                },
                other => other, // e.g. the activation limit: judged below like any other answer
            };
        }

        if let Some(token) = v.as_ref().and_then(Answer::token) {
            match self.check_token(&token, &s) {
                r @ Ok(Verified::Revoked(_)) => {
                    // The one answer that locks: signed by the server, about this key.
                    let _ = self.storage.save(None);
                    return Self::status(r, false);
                }
                r @ Ok(_) => {
                    s.token = token;
                    let _ = self.storage.save(Some(&s));
                    return Self::status(r, false);
                }
                Err(_) => {}
            }
        }
        // No answer, or an answer without a usable signed licence: judge by the one already held.
        let _ = self.storage.save(Some(&s));
        Self::status(self.check_token(&s.token, &s), true)
    }

    /// Judges the stored licence without the network: for a quick start-up
    /// before [`check`](Self::check) has answered.
    pub fn check_offline(&self) -> Status {
        let Some(mut s) = self.storage.load() else { return Status::Inactive { reason: None } };
        let now = (self.clock)();
        if now > s.high_water {
            s.high_water = now;
            let _ = self.storage.save(Some(&s));
        }
        Self::status(self.check_token(&s.token, &s), true)
    }

    /// "Deactivate this computer": frees the seat. Forgets the licence only when the server confirmed.
    pub fn deactivate(&self) -> Result<(), Error> {
        let Some(s) = self.storage.load() else { return Ok(()) };
        let d = self.call("deactivate", &[("license_key", &s.key), ("instance_id", &s.instance_id)]).ok_or(Error::Unreachable)?;
        if d.flag("deactivated") || d.error() == Some(INSTANCE_NOT_FOUND) {
            return self.storage.save(None).map_err(Error::Storage);
        }
        Err(Error::Refused(d.error().unwrap_or("This computer could not be deactivated.").to_string()))
    }

    /// The licence this app holds, if any.
    pub fn stored(&self) -> Option<StoredLicence> {
        self.storage.load()
    }
}
