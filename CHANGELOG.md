# Changelog

All notable changes to this crate are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the crate follows
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-17

First release: the copy-paste Rust client and verifier from License Worker's
docs, packaged as one crate.

### Added

- `LicenseClient`: `activate`, `check`, `check_offline`, `deactivate`, with a
  blocking `ureq` 2 transport (Windows' own TLS on Windows, rustls elsewhere).
- The client rules: only a signed revocation locks; offline, the stored licence
  decides; a high-water clock; quiet re-activation on `instance_id not found.`;
  the seat is given back when the app refuses a licence.
- `verify`: the Ed25519 verifier of the signed licence `v1.<payload>.<sig>`,
  with kid-based key rotation, tested against the 16 shared test vectors.
- Storage: `FileStorage`, `MemoryStorage`, and `KeyringStorage` behind the
  `keyring` feature (Windows Credential Manager, macOS Keychain, Linux Secret
  Service). `default_instance_name()` from the computer name.
- `Transport`, so tests can script a server and run offline.
- The `license-worker-client` command, in the contract License Worker's
  `npm run check:clients` drives.

[0.1.0]: https://github.com/licenseworker/license-worker-client/releases/tag/v0.1.0
