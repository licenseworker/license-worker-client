//! A scripted License Worker for offline tests: signs real licences with the
//! published test keys of the shared vectors.
#![allow(dead_code)]
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use license_worker_client::{key_hash, HttpResponse, Transport, TransportError};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

pub const NOW: i64 = 1_796_126_400; // 2026-12-02T00:00:00Z
pub const PRODUCT: i64 = 4_100_105;
pub const KEY: &str = "38b1460a-5104-4067-a91d-77b872934d51";

pub struct TestKey {
    pub kid: &'static str,
    seed: &'static str,
}

pub const K1: TestKey = TestKey { kid: "k-test-1", seed: "mpZYGxpSo79bCr+O9bl88ij3nsGHghlEhLZBVGl1toc=" };
pub const K2: TestKey = TestKey { kid: "k-test-2", seed: "8IcDKAFP3zBH/KCp7FxPZyD/LiN4kvrY4Opthyq/hqw=" };
/// Not embedded in the app.
pub const K9: TestKey = TestKey { kid: "k-test-9", seed: "llqL0IjPcgfSHx4KoH3BDAqaZWokcQdnQTOelFKUCu0=" };

impl TestKey {
    fn signing(&self) -> SigningKey {
        SigningKey::from_bytes(&STANDARD.decode(self.seed).unwrap().try_into().unwrap())
    }
    pub fn public_b64(&self) -> String {
        STANDARD.encode(self.signing().verifying_key().to_bytes())
    }
}

/// What the app embeds: k-test-1 and k-test-2.
pub fn app_keys() -> HashMap<String, String> {
    HashMap::from([(K1.kid.to_string(), K1.public_b64()), (K2.kid.to_string(), K2.public_b64())])
}

pub struct Licence<'a> {
    pub key: &'a TestKey,
    pub typ: &'a str,
    pub product_id: i64,
    pub instance_id: Option<&'a str>,
    pub exp: Option<i64>,
}

pub fn sign(l: &Licence) -> String {
    let mut p = json!({
        "v": 1, "kid": l.key.kid, "typ": l.typ, "key_hash": key_hash(KEY), "store_id": 100200,
        "product_id": l.product_id, "variant_id": 5100105, "instance_id": l.instance_id, "iat": NOW - 60, "exp": l.exp,
    });
    if l.typ == "revoked" {
        p["reason"] = json!("disabled");
    }
    let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&p).unwrap());
    let input = format!("v1.{body}");
    let sig = l.key.signing().sign(input.as_bytes());
    format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig.to_bytes()))
}

pub fn licence(instance_id: &str) -> String {
    sign(&Licence { key: &K1, typ: "license", product_id: PRODUCT, instance_id: Some(instance_id), exp: None })
}

pub fn revocation() -> String {
    sign(&Licence { key: &K1, typ: "revoked", product_id: PRODUCT, instance_id: None, exp: None })
}

pub fn reply(status: u16, body: Value) -> Result<HttpResponse, TransportError> {
    Ok(HttpResponse { status, body: body.to_string() })
}

pub fn activated(instance_id: &str, token: String) -> Result<HttpResponse, TransportError> {
    reply(200, json!({"activated": true, "error": null, "instance": {"id": instance_id, "name": "test"}, "token": token}))
}

pub fn validated(instance_id: &str, token: String) -> Result<HttpResponse, TransportError> {
    reply(200, json!({"valid": true, "error": null, "instance": {"id": instance_id}, "token": token}))
}

pub fn offline() -> Result<HttpResponse, TransportError> {
    Err(TransportError("connection refused".into()))
}

type Handler = Box<dyn Fn(&str, &HashMap<String, String>) -> Result<HttpResponse, TransportError> + Send + Sync>;

/// Answers each request with the handler; records (action, fields).
pub struct Scripted {
    handler: Mutex<Handler>,
    pub calls: Mutex<Vec<(String, HashMap<String, String>)>>,
}

impl Scripted {
    pub fn new(handler: impl Fn(&str, &HashMap<String, String>) -> Result<HttpResponse, TransportError> + Send + Sync + 'static) -> Self {
        Scripted { handler: Mutex::new(Box::new(handler)), calls: Mutex::new(Vec::new()) }
    }
    pub fn set(&self, handler: impl Fn(&str, &HashMap<String, String>) -> Result<HttpResponse, TransportError> + Send + Sync + 'static) {
        *self.handler.lock().unwrap() = Box::new(handler);
    }
    pub fn actions(&self) -> Vec<String> {
        self.calls.lock().unwrap().iter().map(|c| c.0.clone()).collect()
    }
}

impl Transport for Scripted {
    fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<HttpResponse, TransportError> {
        let action = url.rsplit('/').next().unwrap().to_string();
        assert!(url.starts_with("https://license.test/v1/licenses/"), "unexpected url {url}");
        let f: HashMap<String, String> = fields.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        self.calls.lock().unwrap().push((action.clone(), f.clone()));
        (self.handler.lock().unwrap())(&action, &f)
    }
}
