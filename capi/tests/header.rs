//! include/license_worker.h must be what cbindgen makes of src/lib.rs.
//! UPDATE_HEADER=1 cargo test -p license-worker-client-capi --test header  rewrites it.
use std::path::Path;

#[test]
fn header_is_current() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut config = cbindgen::Config::from_file(dir.join("cbindgen.toml")).unwrap();
    // The version, as macros: so a C build can check at compile time what lw_version() says at run time.
    config.after_includes = Some(format!(
        "\n#define LW_VERSION_MAJOR {}\n#define LW_VERSION_MINOR {}\n#define LW_VERSION_PATCH {}\n#define LW_VERSION_STRING \"{}\"",
        env!("CARGO_PKG_VERSION_MAJOR"),
        env!("CARGO_PKG_VERSION_MINOR"),
        env!("CARGO_PKG_VERSION_PATCH"),
        env!("CARGO_PKG_VERSION"),
    ));
    let mut out = Vec::new();
    cbindgen::Builder::new().with_crate(dir).with_config(config).generate().expect("cbindgen").write(&mut out);
    // Line endings are not content: cbindgen and git may both write CRLF on Windows.
    let generated = String::from_utf8(out).unwrap().replace("\r\n", "\n");
    let path = dir.join("include/license_worker.h");
    if std::env::var_os("UPDATE_HEADER").is_some() {
        std::fs::write(&path, &generated).unwrap();
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default().replace("\r\n", "\n");
    assert!(committed == generated, "{} is stale: run UPDATE_HEADER=1 cargo test -p license-worker-client-capi --test header", path.display());
}
