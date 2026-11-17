# Reporting a security problem

If you find a way to make this client accept a licence it should not (a
forged, altered, replayed or expired one, one for another key, product or
computer), to make it lock out a licence that is good, to get past the
high-water clock, to read the stored licence where it should be protected,
or a memory-safety problem in the C interface (a crash, a panic that
crosses into C, a read or write out of bounds), please tell us privately:

**support@licenseworker.com**, subject starting with `SECURITY`.

Please do not open a public issue for it, and do not test against a licence
server that is not yours.

What helps: the version (`Cargo.toml`, or `lw_version()`), the platform,
what you did, what happened, and what you expected. We answer within three
business days, and say when a fix is out. A fix is released as a new version
and a GitHub Release, with a note in `CHANGELOG.md` that it is a security
fix and what to do when updating.

## Supported versions

The latest release. While the crate is 0.x, a fix lands in a new release,
not in a back-port to an older one.

## Not a bug in this client

- **Patching the app.** Code running on the user's own computer can be
  changed: a cracked binary that skips the check is not something a client
  library can prevent. The signed licence makes a forged answer from a fake
  server useless, which is what this client is for.
- **Anything about the server.** A problem in License Worker itself goes to
  the same address, and is handled under its own policy.

## If your signing key leaks

Move the server to its backup key, publish a new backup key, and release
your app with both new public keys embedded. An app that embeds both keys
keeps working across the move; see License Worker's `docs/operations.md`,
"Rotating the signing key".
