# EveryAI vault, format v1 (V0: spec, threat model, vectors)

Status: **design + dev-only code**. Nothing here ships in a release build, and the hosted server refuses vault
blobs unless `VAULT_SYNC_DEV=true` (refused at start in production). Sync goes to production only after an
external security review (TODO-accounts.md §6, phases V3/V4).

All cryptography is libsodium (owner's choice): `crypto_pwhash` (Argon2id 1.3), `crypto_aead_xchacha20poly1305_ietf`,
`crypto_generichash` (BLAKE2b), `crypto_sign` (Ed25519) and `crypto_kx` (X25519 + BLAKE2b). The app uses the
`sodium` Dart binding (BSD-3-Clause), whose build hooks bundle libsodium per platform.
[`vectors.json`](vectors.json) is produced by [`make_vectors.py`](make_vectors.py) straight from libsodium; the
app's tests reproduce every byte of it.

## Threat model

What the vault protects: the user's secrets (logins, API keys, later per-site sessions) stored on our server so
their devices can share them.

| Threat | What stops it |
| --- | --- |
| **Compromised server or VM** reads or rewrites blobs | The server holds ciphertext and metadata only. The vault key never leaves devices unwrapped. Every item is authenticated with its id and version, and the manifest is signed by a key only devices hold, so a swapped, edited or dropped item is detected. |
| **Rollback / replay** of an older blob or manifest | Manifests carry a version; each device keeps the highest version it has verified and refuses a lower one. Items carry their version in the AAD. A brand-new device can't detect a rollback older than its join; the approving device sends the current manifest version with the vault key. |
| **Stolen mailbox** (magic-link sign-in) | Sign-in gives access to the account, not the vault: unlocking needs the passphrase, the recovery key, or approval from a device that already has the vault key. |
| **Weak passphrase, offline guessing** after a server breach | Argon2id with at least 64 MiB and 3 passes (above OWASP's 19 MiB/2 minimum). The recovery key is 256 random bits and not guessable. Users are told a passphrase alone is only as strong as itself. |
| **Lost device** | The device's copy is wrapped like the server's; a lost unlocked device is the user's to revoke (remove the device, rotate the vault key: V2+). |
| **Lost passphrase** | The recovery key (shown once, to print or store) unwraps the vault key. Losing both loses the vault: there is no server-side reset, by design. |
| **Malicious or buggy client** | A client with the vault key can do anything; we limit what a buggy one breaks: strict decoders that refuse unknown versions and lengths (fuzzed), no partial writes. |
| **Screenshots, logs** | Items are never logged; plaintext stays in memory only while unlocked (`SecureKey`s are zeroed on lock). UI screens that show secrets are excluded from screenshots where the OS allows. |
| **Harness agents** (Code sessions) reading the vault | The vault folder is on the tools' credential-store refusal list (`exfil.dart`), for every lead and mode, with a test. |

Out of scope for v1: a compromised OS or keylogger on an unlocked device; side channels in libsodium; cookie
sync (needs its own design: per-site opt-in, short lifetimes, deny lists).

## Keys

| Key | What it is | Wrapped by |
| --- | --- | --- |
| **VK**, vault key | 32 random bytes | the passphrase KEK, the recovery KEK, and for a joining device a `crypto_kx` session key |
| **Passphrase KEK** | `crypto_pwhash(32, passphrase (UTF-8 as typed; NFC normalisation is a V2 item), salt[16], ops, mem, ARGON2ID13)` | — |
| **RK**, recovery key | 32 random bytes, shown as `EV1-` + Crockford base32 in groups of 4 | — |
| **Recovery KEK** | `crypto_generichash(32, "everyai-vault/v1\|recovery", key = RK)` | — |
| **Signing seed** | 32 random bytes → `crypto_sign_seed_keypair` (Ed25519) | VK |
| **IK**, item key | 32 random bytes per item (a new one per version) | VK |

Real vaults use `ops = 3`, `mem = 64 MiB` or more (stored in the header so they can rise later). The vectors use
`ops = 2`, `mem = 8 MiB` to keep tests fast.

## Encryption

Every encryption is XChaCha20-Poly1305 IETF with a fresh random 24-byte nonce and associated data (AAD) built as
`everyai-vault/v1|<purpose>|<fields…>` (UTF-8, `|`-joined):

| What | Key | AAD |
| --- | --- | --- |
| VK under the passphrase | passphrase KEK | `…\|wrap\|password\|<vault_id>` |
| VK under the recovery key | recovery KEK | `…\|wrap\|recovery\|<vault_id>` |
| Signing seed | VK | `…\|wrap\|signing\|<vault_id>` |
| Item key | VK | `…\|item-key\|<vault_id>\|<item_id>\|<version>` |
| Item body (JSON) | IK | `…\|item\|<vault_id>\|<item_id>\|<version>` |
| VK to a joining device | `crypto_kx` approver `tx` key | `…\|join\|<vault_id>` |

## Files

`vault.json` (the header):

```json
{ "v": 1, "vault_id": "…",
  "kdf": { "alg": "argon2id13", "ops": 3, "mem": 67108864, "salt": "b64" },
  "password": { "nonce": "b64", "ct": "b64" },
  "recovery": { "nonce": "b64", "ct": "b64" },
  "signing":  { "public": "b64", "nonce": "b64", "ct": "b64" } }
```

An item: `{ "v": 1, "id", "version", "key_nonce", "key_ct", "nonce", "ct" }`. The manifest is canonical JSON
(no spaces, keys in this order, items sorted by id):
`{"v":1,"vault_id":…,"version":N,"items":[{"id":…,"version":…,"digest":"<hex BLAKE2b-256 of the item ct>"}]}`,
signed with `crypto_sign_detached("everyai-vault/v1|manifest|" + bytes)`. Decoders refuse a `v` other than 1,
nonces not 24 bytes, ciphertexts under 16 bytes, keys not 32 bytes, and unknown `kdf.alg`.

## Joining a device

1. The new device makes a `crypto_kx` key pair and shows its public key (QR, or through the relay).
2. The approving device makes its own `crypto_kx` key pair and computes the server-side session keys
   (`crypto_kx_server_session_keys`); it sends its public key, the VK sealed under its `tx` key (AAD
   `…|join|<vault_id>`) and the current manifest version.
3. The new device computes the client-side keys (its `rx` equals the approver's `tx`) and opens the VK.
4. Both show a 6-digit code: the first 4 bytes of `BLAKE2b-256(approver_public ‖ device_public)` as a big-endian
   number mod 10⁶. The user confirms they match before step 2 sends anything, so a relay in the middle is caught.

## Recovery

The recovery key unwraps the VK on any device; the user then sets a new passphrase (new salt, new password wrap)
and is offered a new recovery key (a new recovery wrap; the old one stops working once the header is replaced).
