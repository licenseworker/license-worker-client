# The License Worker protocol

What this client expects from a licence server, written so that anyone can
run a compatible server, or write a compatible client in another language.
[License Worker](https://github.com/licenseworker) is the reference server;
nothing here depends on it.

The protocol has two halves:

1. **Three HTTP calls**, the same as the Lemon Squeezy License API, so code
   written for Lemon Squeezy keeps working.
2. **A signed licence** (`token`) in the answers, so an app can open offline
   and a forged or replayed answer is worthless.

The words *must* and *should* are meant as in RFC 2119.

## 1. The calls

```
POST {server}/v1/licenses/activate     license_key, instance_name
POST {server}/v1/licenses/validate     license_key, instance_id (optional)
POST {server}/v1/licenses/deactivate   license_key, instance_id
```

Requests are `application/x-www-form-urlencoded` (a server should accept JSON
too) with `Accept: application/json`. Answers are JSON objects.

### Licence keys

The reference server issues keys as UUIDs (`38b1460a-5104-4067-a91d-77b872934d51`)
and treats any other string as unknown. A key is compared after removing all
whitespace and lowercasing it, so a pasted key with stray spaces or in capitals
is the same key. The client sends the key as the user typed it, trimmed.

### Answers

The client reads only the fields below. A server should also send the rest of
the Lemon Squeezy answer (`license_key`, `meta`), which other clients read.

**activate**

| Situation | HTTP | Body (fields the client reads) |
|---|---|---|
| Activated | 200 | `activated: true`, `error: null`, `instance: {id, name, created_at}`, `token`: a licence for that instance |
| Key disabled, refunded or expired | 400 | `activated: false`, `error`, `instance: null`, `token`: a **revocation** |
| Activation limit reached | 400 | `activated: false`, `error: "This license key has reached the activation limit."`, `token: null` |
| Unknown key | 404 | `activated: false`, `error: "license_key not found."` (no `token` field) |
| Missing field | 422 | `{message, errors: {field: [...]}}`, no flag |

**validate**

| Situation | HTTP | Body |
|---|---|---|
| Good key, known instance (or none given) | 200 | `valid: true`, `error: null`, `instance` (or `null`), `token`: a licence |
| Key disabled, refunded or expired | 400 | `valid: false`, `error`, `token`: a **revocation** |
| Instance not known (released, or never existed) | 404 | `valid: false`, `error: "instance_id not found."` exactly, no `token` |
| Unknown key | 404 | `valid: false`, `error: "license_key not found."`, no `token` |

**deactivate**

| Situation | HTTP | Body |
|---|---|---|
| Released | 200 | `deactivated: true`, `error: null`, `token: null` |
| Instance not known | 404 | `deactivated: false`, `error: "instance_id not found."` |

Deactivation must be allowed whatever the key's status: giving a seat back
never hurts.

**Everything else** (a rate limit, an outage) must be **429** or **5xx**.
Clients treat those as *no answer*, never as a refusal, so a definitive
answer must never use them. The reference server sends
`Too many requests. Please try again later.` with 429 and
`The license service is temporarily unavailable. Please try again.` with 503.

## 2. The signed licence

```
token     = "v1." + b64url(payload JSON) + "." + b64url(signature)
signature = Ed25519 over the ASCII bytes of "v1." + b64url(payload JSON)
```

`b64url` is base64url without padding. The payload is a JSON object:

| Field | Type | Meaning |
|---|---|---|
| `v` | number | format version, `1` |
| `kid` | string | which of the server's keys signed it |
| `typ` | `"license"` or `"revoked"` | a licence, or a signed revocation |
| `key_hash` | string | sha256, lowercase hex, of the licence key with all whitespace removed and lowercased |
| `store_id` | number | the store |
| `product_id`, `variant_id` | number | what the key is for |
| `instance_id` | string or null | the activation it was issued to; null when validated without one |
| `iat` | number | issued at, unix seconds |
| `exp` | number or null | expires at, unix seconds; null is perpetual |
| `reason` | string, revocations only | `disabled`, `refunded` or `expired` |

The licence key itself is never in the token. The reference server writes the
fields in the order above with no whitespace; a verifier parses the JSON, so
the order matters only to reproduce a token byte for byte.

### Verifying, in order

1. Three parts separated by `.`, else *malformed*. The first is `v1`, else *unsupported_version*.
2. The payload decodes to JSON of the shape above, else *malformed*; `v` is 1, else *unsupported_version*; the signature is 64 bytes, else *bad_signature*.
3. `kid` names one of the public keys the app embeds, else *unknown_kid*. `kid` only chooses the key: nothing in the payload is trusted yet.
4. The signature verifies over the first two parts, dot included, else *bad_signature*.
5. `key_hash` is the hash of the key the app holds, else *wrong_key*. The product (or variant) is one the app accepts, else *wrong_product*.
6. `typ` is `revoked`: the result is **revoked**, whatever the instance. It is about the key.
7. `instance_id` is the app's own activation, else *wrong_instance*.
8. `exp` is null: **valid**. Otherwise, with `now = max(clock, the latest time this device has seen)`: up to `exp` **valid**, up to `exp + grace` (14 days by default) **grace**, later *expired*.

### Keys and rotation

The server signs with one Ed25519 key at a time and publishes two public keys
(raw 32 bytes, base64), the active one and a backup, each with its `kid`. Apps
embed both. The server can then move to the backup key without an app
release, and tokens signed before keep verifying.

## 3. What a client must do

These are the rules this crate follows. A client that breaks them locks out
paying customers, or lets a forged answer through.

1. **Only a signed revocation locks.** Lock only on a token that verifies to
   *revoked*; then either forget the stored licence (the Rust client) or keep
   the revocation, to show its reason at the next launch (the Swift one). A timeout, a 429, a 5xx, an
   unsigned `valid: false`, `license_key not found.` or a token that fails to
   verify all leave the app as it was.
2. **Store the licence and judge by it offline.** Keep the key, the instance
   id and the last token. With no usable answer, verify the stored token.
3. **Keep a high-water clock.** Store the latest time seen and verify
   against `max(now, that)`, so setting the clock back cannot stretch an
   expired licence.
4. **Embed both public keys.**
5. **On `instance_id not found.`, activate again, quietly,** with the same
   key, and carry on with the new instance.
6. **Give the seat back when the app refuses a licence** the server just
   granted (another product, a key the app does not embed, or one it cannot
   store): deactivate it before reporting the error.

## 4. Test vectors

[`tests/vectors/license-token-v1.json`](tests/vectors/license-token-v1.json)
has three published throwaway keys, a licence key, and 16 tokens with the
verdict each must get: a perpetual licence, the backup key, an unknown key, a
forgery, a changed payload, a changed signature, another product, another
instance, an expiring licence before, during and after its grace, a clock set
back against the high-water mark, a clock set far back and far forward, a
revocation, and a string that is not a token. A verifier in any language is
correct when it gets all 16. Ed25519 is deterministic, so a signer can
reproduce every token byte for byte.

The seeds in that file are public. They must never sign a real licence.
