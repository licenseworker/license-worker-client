//! How the client reaches the server. [`UreqTransport`] is the real one;
//! implement [`Transport`] to script a server in tests, or to route requests
//! through your own HTTP stack.
use std::fmt;
use std::time::Duration;

/// An HTTP answer with any status, as the server sent it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// The HTTP status code.
    pub status: u16,
    /// The body, as text (JSON from a License Worker server).
    pub body: String,
}

/// No HTTP answer at all: no network, DNS, TLS, timeout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError(
    /// What went wrong, for logs.
    pub String,
);

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for TransportError {}

/// Sends one request to the server. [`UreqTransport`] is the real one; tests
/// implement it to script answers.
pub trait Transport {
    /// POSTs `fields` as `application/x-www-form-urlencoded` with `Accept: application/json`.
    /// Every HTTP status, 4xx and 5xx included, is an `Ok`.
    fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<HttpResponse, TransportError>;
}

impl<T: Transport + ?Sized> Transport for &T {
    fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<HttpResponse, TransportError> {
        (**self).post_form(url, fields)
    }
}

impl<T: Transport + ?Sized> Transport for Box<T> {
    fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<HttpResponse, TransportError> {
        (**self).post_form(url, fields)
    }
}

impl<T: Transport + ?Sized> Transport for std::sync::Arc<T> {
    fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<HttpResponse, TransportError> {
        (**self).post_form(url, fields)
    }
}

/// Blocking HTTPS through `ureq` 2: Windows' own TLS (schannel) on Windows, rustls with the webpki roots elsewhere.
#[derive(Clone)]
pub struct UreqTransport {
    agent: ureq::Agent,
}

impl UreqTransport {
    /// A transport with `timeout` per request and the crate's user agent.
    pub fn new(timeout: Duration) -> Self {
        let agent = ureq::AgentBuilder::new().timeout(timeout).user_agent(concat!("license-worker-client/", env!("CARGO_PKG_VERSION"))).build();
        UreqTransport { agent }
    }

    /// Uses an agent you configured (proxy, TLS, timeouts).
    pub fn with_agent(agent: ureq::Agent) -> Self {
        UreqTransport { agent }
    }
}

impl fmt::Debug for UreqTransport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("UreqTransport")
    }
}

impl Transport for UreqTransport {
    fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<HttpResponse, TransportError> {
        let resp = match self.agent.post(url).set("Accept", "application/json").send_form(fields) {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => return Err(TransportError(e.to_string())),
        };
        let status = resp.status();
        let body = resp.into_string().map_err(|e| TransportError(e.to_string()))?;
        Ok(HttpResponse { status, body })
    }
}
