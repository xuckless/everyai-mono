#!/usr/bin/env python3
"""Test vectors for the EveryAI vault format v1 (docs/vault/format.md), made
with libsodium itself through ctypes (no packages). Every input is fixed, so
a rerun gives the same file:

    python3 docs/vault/make_vectors.py /opt/homebrew/lib/libsodium.dylib > docs/vault/vectors.json

The app's tests (frontend/test/features/vault/vault_vectors_test.dart) check
that the Dart implementation produces exactly these bytes.
"""
import base64, ctypes, json, sys

lib = ctypes.CDLL(sys.argv[1] if len(sys.argv) > 1 else "libsodium.dylib")
assert lib.sodium_init() >= 0
D = b"everyai-vault/v1"
b64 = lambda b: base64.b64encode(bytes(b)).decode()
fixed = lambda tag, n: bytes((i * 7 + sum(tag.encode())) % 256 for i in range(n))  # deterministic filler

def aad(*parts): return b"|".join([D, *[p if isinstance(p, bytes) else str(p).encode() for p in parts]])

def seal(msg, nonce, key, ad):
    out = ctypes.create_string_buffer(len(msg) + 16); n = ctypes.c_ulonglong()
    assert lib.crypto_aead_xchacha20poly1305_ietf_encrypt(out, ctypes.byref(n), msg, ctypes.c_ulonglong(len(msg)), ad, ctypes.c_ulonglong(len(ad)), None, nonce, key) == 0
    return out.raw[: n.value]

def pwhash(pw, salt, ops, mem):
    out = ctypes.create_string_buffer(32)
    alg = lib.crypto_pwhash_alg_argon2id13()
    assert lib.crypto_pwhash(out, ctypes.c_ulonglong(32), pw, ctypes.c_ulonglong(len(pw)), salt, ctypes.c_ulonglong(ops), ctypes.c_size_t(mem), alg) == 0
    return out.raw

def blake(msg, key=None, n=32):
    out = ctypes.create_string_buffer(n)
    assert lib.crypto_generichash(out, ctypes.c_size_t(n), msg, ctypes.c_ulonglong(len(msg)), key, ctypes.c_size_t(len(key) if key else 0)) == 0
    return out.raw

def sign_keys(seed):
    pk, sk = ctypes.create_string_buffer(32), ctypes.create_string_buffer(64)
    assert lib.crypto_sign_seed_keypair(pk, sk, seed) == 0
    return pk.raw, sk.raw

def sign(msg, sk):
    sig = ctypes.create_string_buffer(64)
    assert lib.crypto_sign_detached(sig, None, msg, ctypes.c_ulonglong(len(msg)), sk) == 0
    return sig.raw

def kx_keys(seed):
    pk, sk = ctypes.create_string_buffer(32), ctypes.create_string_buffer(32)
    assert lib.crypto_kx_seed_keypair(pk, sk, seed) == 0
    return pk.raw, sk.raw

def kx_server(pk, sk, client_pk):
    rx, tx = ctypes.create_string_buffer(32), ctypes.create_string_buffer(32)
    assert lib.crypto_kx_server_session_keys(rx, tx, pk, sk, client_pk) == 0
    return rx.raw, tx.raw

vault_id = "v-0001"
vk = fixed("vault key", 32)
ops, mem = 2, 8 << 20  # vector parameters (small, fast); real vaults use format.md's
salt = fixed("salt", 16)
passphrase = "correct horse battery staple ✓".encode()
kek = pwhash(passphrase, salt, ops, mem)
n_pw = fixed("nonce password", 24)
rk = fixed("recovery key", 32)
kek_r = blake(D + b"|recovery", key=rk)
n_rk = fixed("nonce recovery", 24)
seed = fixed("signing seed", 32)
spk, ssk = sign_keys(seed)
n_seed = fixed("nonce signing", 24)
item_id, item_version = "item-1", 3
ik = fixed("item key", 32)
n_ik = fixed("nonce item key", 24)
n_body = fixed("nonce item body", 24)
plaintext = json.dumps({"kind": "login", "site": "example.com", "user": "ada", "secret": "hunter2"}, separators=(",", ":")).encode()
body = seal(plaintext, n_body, ik, aad("item", vault_id, item_id, item_version))
manifest = json.dumps({"v": 1, "vault_id": vault_id, "version": 7, "items": [{"id": item_id, "version": item_version, "digest": blake(body).hex()}]}, separators=(",", ":")).encode()
eph_pk, eph_sk = kx_keys(fixed("join approver", 32))
new_pk, new_sk = kx_keys(fixed("join device", 32))
rx, tx = kx_server(eph_pk, eph_sk, new_pk)
n_join = fixed("nonce join", 24)
confirm = int.from_bytes(blake(eph_pk + new_pk)[:4], "big") % 1_000_000

print(json.dumps({
    "comment": "EveryAI vault format v1 vectors, made by docs/vault/make_vectors.py with libsodium. All binary values base64.",
    "libsodium": ctypes.c_char_p(lib.sodium_version_string()).value.decode() if (setattr(lib.sodium_version_string, "restype", ctypes.c_char_p) or True) else "",
    "vault_id": vault_id,
    "vault_key": b64(vk),
    "kdf": {"alg": "argon2id13", "ops": ops, "mem": mem, "salt": b64(salt), "passphrase_utf8": b64(passphrase), "kek": b64(kek)},
    "password_wrap": {"nonce": b64(n_pw), "aad": b64(aad("wrap", "password", vault_id)), "ct": b64(seal(vk, n_pw, kek, aad("wrap", "password", vault_id)))},
    "recovery": {"key": b64(rk), "kek": b64(kek_r), "nonce": b64(n_rk), "ct": b64(seal(vk, n_rk, kek_r, aad("wrap", "recovery", vault_id)))},
    "signing": {"seed": b64(seed), "public": b64(spk), "nonce": b64(n_seed), "ct": b64(seal(seed, n_seed, vk, aad("wrap", "signing", vault_id)))},
    "item": {"id": item_id, "version": item_version, "key": b64(ik), "key_nonce": b64(n_ik),
             "key_ct": b64(seal(ik, n_ik, vk, aad("item-key", vault_id, item_id, item_version))),
             "nonce": b64(n_body), "plaintext": b64(plaintext), "ct": b64(body)},
    "manifest": {"bytes": b64(manifest), "signature": b64(sign(D + b"|manifest|" + manifest, ssk))},
    "join": {"approver_public": b64(eph_pk), "approver_secret": b64(eph_sk), "device_public": b64(new_pk), "device_secret": b64(new_sk),
             "approver_tx": b64(tx), "nonce": b64(n_join), "ct": b64(seal(vk, n_join, tx, aad("join", vault_id))), "confirm": f"{confirm:06d}"},
}, indent=2, ensure_ascii=False))
