//! The C ABI's own contract, called as C would call it.
use license_worker::*;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

fn s(p: *const c_char) -> String {
    unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string()
}

struct Cfg {
    _strings: Vec<CString>,
    _ptrs: Vec<Vec<*const c_char>>,
    cfg: LwConfig,
}

fn config(storage: &str) -> Cfg {
    let url = CString::new("http://127.0.0.1:9").unwrap(); // nothing listens: offline
    let kid = CString::new("k1").unwrap();
    let key = CString::new("MwhKI3s/ZgWNKaAhSHr9JM8YjI5bEuFREV5QcIWDJiY=").unwrap();
    let path = CString::new(storage).unwrap();
    let kids = vec![kid.as_ptr()];
    let keys = vec![key.as_ptr()];
    let cfg = LwConfig {
        server_url: url.as_ptr(),
        key_ids: kids.as_ptr(),
        public_keys: keys.as_ptr(),
        key_count: 1,
        product_ids: ptr::null(),
        product_count: 0,
        variant_ids: ptr::null(),
        variant_count: 0,
        instance_name: ptr::null(),
        grace_days: 0,
        timeout_ms: 500,
        storage_path: path.as_ptr(),
        keyring_service: ptr::null(),
    };
    Cfg { _strings: vec![url, kid, key, path], _ptrs: vec![kids, keys], cfg }
}

fn temp(name: &str) -> String {
    std::env::temp_dir().join(format!("lw-capi-{}-{name}.json", std::process::id())).to_string_lossy().into_owned()
}

#[test]
fn a_bad_config_is_refused_with_a_message() {
    unsafe {
        let mut err: *mut c_char = ptr::null_mut();
        assert!(lw_client_new(ptr::null(), &mut err).is_null());
        assert_eq!(s(err), "config is NULL");
        lw_string_free(err);

        let mut c = config(&temp("bad"));
        c.cfg.key_count = 0;
        assert!(lw_client_new(&c.cfg, &mut err).is_null());
        assert!(s(err).contains("public keys"));
        lw_string_free(err);

        let mut c = config(&temp("bad"));
        c.cfg.storage_path = ptr::null();
        assert!(lw_client_new(&c.cfg, ptr::null_mut()).is_null(), "error may be NULL");

        let bytes = [0xffu8, 0xfe, 0];
        let mut c = config(&temp("bad"));
        c.cfg.server_url = bytes.as_ptr().cast();
        assert!(lw_client_new(&c.cfg, &mut err).is_null());
        assert!(s(err).contains("UTF-8"));
        lw_string_free(err);

        #[cfg(not(feature = "keyring"))]
        {
            let svc = CString::new("com.example.test").unwrap();
            let mut c = config(&temp("bad"));
            c.cfg.keyring_service = svc.as_ptr();
            assert!(lw_client_new(&c.cfg, &mut err).is_null());
            assert!(s(err).contains("keyring"));
            lw_string_free(err);
        }
    }
}

#[test]
fn not_activated_and_offline() {
    let path = temp("offline");
    let c = config(&path);
    unsafe {
        let client = lw_client_new(&c.cfg, ptr::null_mut());
        assert!(!client.is_null());
        let mut st: LwStatus = std::mem::zeroed();
        assert_eq!(lw_check(client, &mut st), LwResult::Ok);
        assert_eq!((st.state, st.unlocked), (LwState::Inactive, false));
        lw_status_clear(&mut st);
        lw_status_clear(&mut st); // twice is fine
        assert_eq!(lw_check_offline(client, &mut st), LwResult::Ok);
        assert!(!st.unlocked);

        let key = CString::new("38b1460a-5104-4067-a91d-77b872934d51").unwrap();
        let mut msg: *mut c_char = ptr::null_mut();
        assert_eq!(lw_activate(client, key.as_ptr(), &mut st, &mut msg), LwResult::Unreachable);
        assert!(s(msg).contains("could not be reached"));
        assert!(!st.unlocked);
        lw_string_free(msg);
        assert_eq!(lw_activate(client, key.as_ptr(), ptr::null_mut(), ptr::null_mut()), LwResult::Unreachable, "out-params are optional");

        assert_eq!(lw_deactivate(client, &mut msg), LwResult::Ok, "nothing to deactivate");
        assert!(msg.is_null());
        assert!(!std::path::Path::new(&path).exists());
        lw_client_free(client);
    }
}

#[test]
fn null_pointers_are_refused_not_dereferenced() {
    unsafe {
        let mut st: LwStatus = std::mem::zeroed();
        assert_eq!(lw_check(ptr::null(), &mut st), LwResult::InvalidArgument);
        assert_eq!(lw_check_offline(ptr::null(), &mut st), LwResult::InvalidArgument);
        assert_eq!(lw_activate(ptr::null(), ptr::null(), &mut st, ptr::null_mut()), LwResult::InvalidArgument);
        assert_eq!(lw_deactivate(ptr::null(), ptr::null_mut()), LwResult::InvalidArgument);
        let c = config(&temp("null"));
        let client = lw_client_new(&c.cfg, ptr::null_mut());
        assert_eq!(lw_check(client, ptr::null_mut()), LwResult::InvalidArgument);
        assert_eq!(lw_activate(client, ptr::null(), &mut st, ptr::null_mut()), LwResult::InvalidArgument);
        lw_client_free(client);
        lw_client_free(ptr::null_mut());
        lw_string_free(ptr::null_mut());
        lw_status_clear(ptr::null_mut());
    }
}

#[test]
fn a_zeroed_status_is_locked() {
    let st: LwStatus = unsafe { std::mem::zeroed() };
    assert_eq!((st.state, st.unlocked), (LwState::Inactive, false));
}

#[test]
fn small_helpers() {
    assert_eq!(s(lw_version()), env!("CARGO_PKG_VERSION"));
    assert_eq!(s(lw_result_name(1)), "unreachable");
    assert_eq!(s(lw_result_name(99)), "unknown");
    let name = lw_default_instance_name();
    assert!(!s(name).is_empty());
    unsafe { lw_string_free(name) };
}
