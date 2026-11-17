//! The client rules, against a scripted server and no network.
mod common;
use common::*;
use license_worker_client::{Error, FileStorage, LicenseClient, MemoryStorage, Options, Status, Storage, StoredLicence};
use serde_json::json;
use std::sync::Arc;

fn options() -> Options {
    Options {
        server_url: "https://license.test/".into(),
        public_keys: app_keys(),
        product_ids: Some(vec![PRODUCT]),
        instance_name: "test-pc".into(),
        ..Default::default()
    }
}

fn now() -> i64 {
    NOW
}

fn client(server: &Arc<Scripted>, storage: &Arc<MemoryStorage>) -> LicenseClient<Arc<MemoryStorage>, Arc<Scripted>> {
    LicenseClient::with_transport(options(), storage.clone(), server.clone()).with_clock(now)
}

fn held(instance_id: &str) -> Arc<MemoryStorage> {
    Arc::new(MemoryStorage::new(Some(StoredLicence { key: KEY.into(), instance_id: instance_id.into(), token: licence(instance_id), high_water: NOW - 100 })))
}

fn open_offline(s: &Status) -> bool {
    s.unlocked() && matches!(s, Status::Valid { offline: true, .. } | Status::Grace { offline: true, .. })
}

#[test]
fn activates_and_stores_the_licence() {
    let server = Arc::new(Scripted::new(|_, f| {
        assert_eq!(f["instance_name"], "test-pc");
        assert_eq!(f["license_key"], KEY, "the key is sent trimmed");
        activated("i-1", licence("i-1"))
    }));
    let storage = Arc::new(MemoryStorage::default());
    let s = client(&server, &storage).activate(&format!("  {KEY}\n")).unwrap();
    assert_eq!(s, Status::Valid { expires: None, offline: false });
    let stored = storage.load().unwrap();
    assert_eq!((stored.key.as_str(), stored.instance_id.as_str(), stored.high_water), (KEY, "i-1", NOW));
}

#[test]
fn an_unknown_key_is_refused_with_the_servers_message() {
    let server = Arc::new(Scripted::new(|_, _| reply(404, json!({"activated": false, "error": "license_key not found."}))));
    let storage = Arc::new(MemoryStorage::default());
    let e = client(&server, &storage).activate("nope").unwrap_err();
    assert!(matches!(e, Error::Refused(_)));
    assert_eq!(e.to_string(), "license_key not found.");
    assert!(storage.load().is_none());
}

#[test]
fn activate_while_offline_changes_nothing() {
    let server = Arc::new(Scripted::new(|_, _| offline()));
    let storage = Arc::new(MemoryStorage::default());
    assert!(matches!(client(&server, &storage).activate(KEY), Err(Error::Unreachable)));
    let server = Arc::new(Scripted::new(|_, _| reply(503, json!({"error": "busy"}))));
    assert!(matches!(client(&server, &storage).activate(KEY), Err(Error::Unreachable)));
    assert!(storage.load().is_none());
}

#[test]
fn a_licence_signed_with_a_key_the_app_does_not_embed_is_refused_and_the_seat_given_back() {
    let server = Arc::new(Scripted::new(|action, f| match action {
        "activate" => activated("i-1", sign(&Licence { key: &K9, typ: "license", product_id: PRODUCT, instance_id: Some("i-1"), exp: None })),
        "deactivate" => {
            assert_eq!(f["instance_id"], "i-1");
            reply(200, json!({"deactivated": true}))
        }
        _ => unreachable!(),
    }));
    let storage = Arc::new(MemoryStorage::default());
    let e = client(&server, &storage).activate(KEY).unwrap_err();
    assert!(matches!(e, Error::NotForThisApp(license_worker_client::Failure::UnknownKid)), "{e:?}");
    assert_eq!(e.to_string(), "This key is not for this app.");
    assert_eq!(server.actions(), ["activate", "deactivate"]);
    assert!(storage.load().is_none());
}

#[test]
fn a_licence_of_another_product_is_refused_and_the_seat_given_back() {
    let server = Arc::new(Scripted::new(|action, _| match action {
        "activate" => activated("i-1", sign(&Licence { key: &K1, typ: "license", product_id: 1, instance_id: Some("i-1"), exp: None })),
        _ => reply(200, json!({"deactivated": true})),
    }));
    let storage = Arc::new(MemoryStorage::default());
    assert!(matches!(client(&server, &storage).activate(KEY), Err(Error::NotForThisApp(license_worker_client::Failure::WrongProduct))));
    assert_eq!(server.actions(), ["activate", "deactivate"]);
}

#[test]
fn the_backup_key_is_accepted() {
    let server =
        Arc::new(Scripted::new(|_, _| activated("i-1", sign(&Licence { key: &K2, typ: "license", product_id: PRODUCT, instance_id: Some("i-1"), exp: None }))));
    let storage = Arc::new(MemoryStorage::default());
    assert!(client(&server, &storage).activate(KEY).unwrap().unlocked());
}

#[test]
fn a_licence_that_cannot_be_stored_gives_the_seat_back() {
    struct Broken;
    impl Storage for Broken {
        fn load(&self) -> Option<StoredLicence> {
            None
        }
        fn save(&self, _: Option<&StoredLicence>) -> std::io::Result<()> {
            Err(std::io::Error::other("disk full"))
        }
    }
    let server = Arc::new(Scripted::new(|action, _| match action {
        "activate" => activated("i-1", licence("i-1")),
        _ => reply(200, json!({"deactivated": true})),
    }));
    let c = LicenseClient::with_transport(options(), Broken, server.clone()).with_clock(now);
    assert!(matches!(c.activate(KEY), Err(Error::Storage(_))));
    assert_eq!(server.actions(), ["activate", "deactivate"]);
}

#[test]
fn not_activated() {
    let server = Arc::new(Scripted::new(|_, _| unreachable!("no request without a stored licence")));
    let storage = Arc::new(MemoryStorage::default());
    assert_eq!(client(&server, &storage).check(), Status::Inactive { reason: None });
    assert!(client(&server, &storage).deactivate().is_ok());
}

#[test]
fn checked_online_takes_the_new_licence() {
    let storage = held("i-1");
    let fresh = sign(&Licence { key: &K1, typ: "license", product_id: PRODUCT, instance_id: Some("i-1"), exp: Some(NOW + 86_400) });
    let t = fresh.clone();
    let server = Arc::new(Scripted::new(move |_, _| validated("i-1", t.clone())));
    assert_eq!(client(&server, &storage).check(), Status::Valid { expires: Some(NOW + 86_400), offline: false });
    let stored = storage.load().unwrap();
    assert_eq!(stored.token, fresh);
    assert_eq!(stored.high_water, NOW, "the high-water mark moves forward");
}

#[test]
fn no_usable_answer_keeps_the_app_open_from_the_stored_licence() {
    let answers: Vec<fn() -> Result<license_worker_client::HttpResponse, license_worker_client::TransportError>> = vec![
        offline,
        || reply(500, json!({"error": "internal"})),
        || reply(502, json!({})),
        || reply(429, json!({"error": "Too many requests."})),
        || reply(200, json!("not an object")),
        || Ok(license_worker_client::HttpResponse { status: 200, body: "<html>captive portal</html>".into() }),
        // An unsigned refusal: only a signed revocation locks.
        || reply(400, json!({"valid": false, "error": "license_key not found."})),
        || reply(200, json!({"valid": false, "error": "This license key is disabled."})),
        // A token that does not verify is no answer either.
        || validated("i-1", sign(&Licence { key: &K9, typ: "revoked", product_id: PRODUCT, instance_id: None, exp: None })),
        || validated("i-1", "v1.garbage.garbage".into()),
    ];
    for (n, answer) in answers.into_iter().enumerate() {
        let storage = held("i-1");
        let server = Arc::new(Scripted::new(move |_, _| answer()));
        let s = client(&server, &storage).check();
        assert!(open_offline(&s), "answer {n}: {s:?}");
        assert!(storage.load().is_some(), "answer {n}: the licence is kept");
    }
}

#[test]
fn a_signed_revocation_locks_and_forgets_the_licence() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|_, _| reply(200, json!({"valid": false, "error": "This license key is disabled.", "token": revocation()}))));
    assert_eq!(client(&server, &storage).check(), Status::Revoked { reason: Some("disabled".into()) });
    assert!(storage.load().is_none());
}

#[test]
fn a_released_activation_is_replaced_quietly() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|action, f| match action {
        "validate" => reply(404, json!({"valid": false, "error": "instance_id not found."})),
        "activate" => {
            assert_eq!(f["license_key"], KEY);
            activated("i-2", licence("i-2"))
        }
        _ => unreachable!(),
    }));
    assert_eq!(client(&server, &storage).check(), Status::Valid { expires: None, offline: false });
    assert_eq!(server.actions(), ["validate", "activate"]);
    let stored = storage.load().unwrap();
    assert_eq!(stored.instance_id, "i-2");
    assert_eq!(stored.token, licence("i-2"));
}

#[test]
fn a_released_activation_that_cannot_be_replaced_is_judged_by_the_stored_licence() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|action, _| match action {
        "validate" => reply(404, json!({"valid": false, "error": "instance_id not found."})),
        _ => reply(400, json!({"activated": false, "error": "This license key has reached the activation limit."})),
    }));
    let s = client(&server, &storage).check();
    assert!(open_offline(&s), "{s:?}");
    assert_eq!(storage.load().unwrap().instance_id, "i-1");
}

#[test]
fn the_high_water_mark_stops_a_clock_set_back() {
    let exp = NOW - 30 * 86_400; // a subscription that ended a month ago
    let token = sign(&Licence { key: &K1, typ: "license", product_id: PRODUCT, instance_id: Some("i-1"), exp: Some(exp) });
    let storage = Arc::new(MemoryStorage::new(Some(StoredLicence { key: KEY.into(), instance_id: "i-1".into(), token, high_water: NOW })));
    let server = Arc::new(Scripted::new(|_, _| offline()));
    fn set_back() -> i64 {
        NOW - 60 * 86_400
    }
    let c = LicenseClient::with_transport(options(), storage.clone(), server).with_clock(set_back);
    assert_eq!(c.check(), Status::Inactive { reason: Some("expired".into()) });
    assert_eq!(c.check_offline(), Status::Inactive { reason: Some("expired".into()) });
    assert_eq!(storage.load().unwrap().high_water, NOW, "never moves back");
}

#[test]
fn grace_after_expiry() {
    let exp = NOW - 86_400;
    let token = sign(&Licence { key: &K1, typ: "license", product_id: PRODUCT, instance_id: Some("i-1"), exp: Some(exp) });
    let storage = Arc::new(MemoryStorage::new(Some(StoredLicence { key: KEY.into(), instance_id: "i-1".into(), token, high_water: NOW })));
    let server = Arc::new(Scripted::new(|_, _| offline()));
    assert_eq!(client(&server, &storage).check(), Status::Grace { expires: Some(exp), offline: true });
}

#[test]
fn check_offline_makes_no_request() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|_, _| unreachable!()));
    assert!(open_offline(&client(&server, &storage).check_offline()));
    assert_eq!(storage.load().unwrap().high_water, NOW);
}

#[test]
fn deactivate_frees_the_seat_and_forgets() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|_, f| {
        assert_eq!((f["license_key"].as_str(), f["instance_id"].as_str()), (KEY, "i-1"));
        reply(200, json!({"deactivated": true}))
    }));
    client(&server, &storage).deactivate().unwrap();
    assert!(storage.load().is_none());
}

#[test]
fn deactivate_of_an_activation_already_gone_forgets_it() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|_, _| reply(404, json!({"deactivated": false, "error": "instance_id not found."}))));
    client(&server, &storage).deactivate().unwrap();
    assert!(storage.load().is_none());
}

#[test]
fn deactivate_offline_keeps_the_licence() {
    let storage = held("i-1");
    let server = Arc::new(Scripted::new(|_, _| offline()));
    assert!(matches!(client(&server, &storage).deactivate(), Err(Error::Unreachable)));
    let server = Arc::new(Scripted::new(|_, _| reply(400, json!({"deactivated": false, "error": "nope"}))));
    assert_eq!(client(&server, &storage).deactivate().unwrap_err().to_string(), "nope");
    assert!(storage.load().is_some());
}

#[test]
fn file_storage_round_trip() {
    let dir = std::env::temp_dir().join(format!("lwc-test-{}", std::process::id()));
    let fs = FileStorage::new(dir.join("nested").join("licence.json"));
    assert!(fs.load().is_none());
    fs.save(None).unwrap();
    let v = StoredLicence { key: KEY.into(), instance_id: "i-1".into(), token: licence("i-1"), high_water: NOW };
    fs.save(Some(&v)).unwrap();
    assert_eq!(fs.load(), Some(v));
    // The harness reads instance_id from the file.
    let raw: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(fs.path()).unwrap()).unwrap();
    assert_eq!(raw["instance_id"], "i-1");
    fs.save(None).unwrap();
    assert!(fs.load().is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn status_serialises_for_a_frontend() {
    assert_eq!(serde_json::to_value(Status::Valid { expires: None, offline: true }).unwrap(), json!({"state": "valid", "expires": null, "offline": true}));
    assert_eq!(serde_json::to_value(Status::Revoked { reason: None }).unwrap(), json!({"state": "revoked", "reason": null}));
}

#[test]
fn instance_name_defaults_to_the_computer_name() {
    assert!(!license_worker_client::default_instance_name().is_empty());
    assert_eq!(Options::default().instance_name, license_worker_client::default_instance_name());
}

#[test]
fn the_client_can_be_shared_across_threads() {
    fn shareable<T: Send + Sync + 'static>() {}
    shareable::<LicenseClient<FileStorage>>();
    shareable::<LicenseClient<MemoryStorage>>();
    #[cfg(feature = "keyring")]
    shareable::<LicenseClient<license_worker_client::KeyringStorage>>();
}
