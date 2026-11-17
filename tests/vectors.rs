//! The shared test vectors of License Worker's signed licence
//! (test-vectors/license-token-v1.json in the server repository).
use license_worker_client::verify::{key_hash, verify, Expect, Options, Verified};
use serde_json::Value;
use std::collections::HashMap;

/// "2027-01-10T00:00:00Z" -> unix seconds (UTC, whole seconds, which is all the vectors use).
fn unix(s: &str) -> i64 {
    let n = |a: usize, b: usize| s[a..b].parse::<i64>().expect("date");
    let (y, m, d) = (n(0, 4), n(5, 7), n(8, 10));
    let (y, m) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + (153 * m + 2) / 5 + d - 1;
    (era * 146_097 + doe - 719_468) * 86_400 + n(11, 13) * 3600 + n(14, 16) * 60 + n(17, 19)
}

fn vectors() -> Value {
    serde_json::from_str(include_str!("vectors/license-token-v1.json")).unwrap()
}

#[test]
fn key_hash_rule() {
    let v = vectors();
    assert_eq!(key_hash(v["license_key"].as_str().unwrap()), v["key_hash"].as_str().unwrap());
    // Whitespace and case do not matter.
    let spaced = format!("  {} \n", v["license_key"].as_str().unwrap().to_uppercase());
    assert_eq!(key_hash(&spaced), v["key_hash"].as_str().unwrap());
}

#[test]
fn every_vector() {
    let v = vectors();
    let keys: HashMap<String, String> = v["trusted_kids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| {
            let kid = k.as_str().unwrap();
            (kid.to_string(), v["keys"][kid]["public_key_b64"].as_str().unwrap().to_string())
        })
        .collect();
    let cases = v["cases"].as_array().unwrap();
    assert!(cases.len() >= 16, "expected the 16 shared vectors");
    let mut failures = Vec::new();
    for c in cases {
        let x = &c["verify"];
        let e = &x["expect"];
        let expect = Expect {
            key_hash: e["key_hash"].as_str().map(String::from),
            product_ids: None,
            variant_ids: e["variant_ids"].as_array().map(|a| a.iter().map(|n| n.as_i64().unwrap()).collect()),
            instance_id: e["instance_id"].as_str().map(String::from),
        };
        let opts = Options {
            grace_seconds: x["grace_seconds"].as_i64().unwrap_or(v["default_grace_seconds"].as_i64().unwrap()),
            high_water_mark: x["high_water_mark"].as_str().map(unix),
        };
        let r = verify(c["token"].as_str().unwrap(), &keys, unix(x["now"].as_str().unwrap()), &expect, opts);
        let want = &c["expected"];
        let pass = match &r {
            Ok(ok) => {
                let state = match ok {
                    Verified::Valid(_) => "valid",
                    Verified::Grace(_) => "grace",
                    Verified::Revoked(_) => "revoked",
                };
                want["ok"] == true && want["state"] == state
            }
            Err(f) => {
                want["ok"] == false && (want["reason"] == f.as_str() || want["also_acceptable"].as_array().is_some_and(|a| a.iter().any(|s| s == f.as_str())))
            }
        };
        if !pass {
            failures.push(format!("{}: got {r:?}, want {want}", c["name"].as_str().unwrap()));
        }
    }
    assert!(failures.is_empty(), "failing vectors:\n{}", failures.join("\n"));
}
