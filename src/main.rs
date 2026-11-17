//! The client as a command, the contract License Worker's `npm run check:clients` drives:
//!
//! ```text
//! license-worker-client <state-file> activate <key> | check | deactivate
//! ```
//!
//! Env: `LW_URL`, `LW_PUBLIC_KEYS` (JSON kid -> key), `LW_PRODUCT_IDS` (comma list).
//! Prints one JSON line.
use license_worker_client::{FileStorage, LicenseClient, Options, Status};
use serde_json::json;
use std::time::Duration;

fn status_json(s: &Status) -> serde_json::Value {
    match s {
        Status::Valid { offline, .. } => json!({"unlocked": true, "state": "valid", "offline": offline}),
        Status::Grace { offline, .. } => json!({"unlocked": true, "state": "grace", "offline": offline}),
        Status::Inactive { reason } => json!({"unlocked": false, "state": "inactive", "reason": reason}),
        Status::Revoked { reason } => json!({"unlocked": false, "state": "revoked", "reason": reason}),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: license-worker-client <state-file> activate <key> | check | deactivate");
        println!("{}", json!({"error": "usage"}));
        std::process::exit(2);
    }
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let product_ids: Vec<i64> = env("LW_PRODUCT_IDS").split(',').filter_map(|s| s.trim().parse().ok()).collect();
    let client = LicenseClient::new(
        Options {
            server_url: env("LW_URL"),
            public_keys: serde_json::from_str(&env("LW_PUBLIC_KEYS")).unwrap_or_default(),
            product_ids: (!product_ids.is_empty()).then_some(product_ids),
            instance_name: "check-clients".into(),
            timeout: Duration::from_secs(3),
            ..Default::default()
        },
        FileStorage::new(&args[1]),
    );
    let out = match args[2].as_str() {
        "activate" => match client.activate(args.get(3).map(String::as_str).unwrap_or("")) {
            Ok(s) => json!({"ok": true, "status": status_json(&s)}),
            Err(e) => json!({"ok": false, "error": e.to_string()}),
        },
        "check" => status_json(&client.check()),
        "deactivate" => match client.deactivate() {
            Ok(()) => json!({"ok": true}),
            Err(e) => json!({"ok": false, "error": e.to_string()}),
        },
        _ => json!({"error": "usage"}),
    };
    println!("{out}");
}
