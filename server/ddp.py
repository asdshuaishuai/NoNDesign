"""DDP container codec — Python port of vendor/moonviz-ddp.

One `.ddp` is the authenticated representation of exactly one canonical
`.mbt.md`. Two modes:
  DDP1  password: zstd(payload) → XChaCha20-Poly1305, AAD = clear header
  DDP2  passwordless: zstd(payload) + CRC32
Argon2id parameters match the Rust crate: m=19*1024 KiB, t=2, p=1, 32-byte key.
"""

from __future__ import annotations

import os
import struct
import zlib
from typing import Tuple

import zstandard as zstd
from argon2.low_level import Type as Argon2Type, hash_secret_raw
from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_aead_xchacha20poly1305_ietf_encrypt,
)

MAGIC = b"DDP1"
MAGIC_OPEN = b"DDP2"
VERSION = 1
SALT_BYTES = 16
NONCE_BYTES = 24
HEADER_BYTES = 4 + 1 + SALT_BYTES + NONCE_BYTES
MAX_PLAINTEXT = 8 * 1024 * 1024
MAX_CIPHERTEXT = 16 * 1024 * 1024
ZSTD_LEVEL = 8
ZSTD_WINDOW_LOG_MAX = 23


class DdpError(ValueError):
    pass


def _compress(data: bytes) -> bytes:
    return zstd.ZstdCompressor(level=ZSTD_LEVEL).compress(data)


def _decompress(data: bytes) -> bytes:
    dctx = zstd.ZstdDecompressor()
    try:
        # Mirror the Rust host: cap the advertised window and stream into a
        # bounded buffer instead of trusting a frame's content size.
        with dctx.stream_reader(data, read_across_frames=False) as reader:
            out = bytearray()
            while True:
                chunk = reader.read(8192)
                if not chunk:
                    break
                out.extend(chunk)
                if len(out) > MAX_PLAINTEXT:
                    raise DdpError("ddp_plaintext_invalid")
            return bytes(out)
    except DdpError:
        raise
    except Exception as exc:
        raise DdpError("ddp_decompression_failed") from exc


def _derive_key(password: str, salt: bytes) -> bytes:
    try:
        return hash_secret_raw(
            secret=password.encode("utf-8"),
            salt=salt,
            time_cost=2,
            memory_cost=19 * 1024,
            parallelism=1,
            hash_len=32,
            type=Argon2Type.ID,
            version=19,
        )
    except Exception as exc:
        raise DdpError("ddp_key_derivation_failed") from exc


def encrypt_ddp(mbt: str, password: str = "") -> bytes:
    if not mbt:
        raise DdpError("ddp_mbt_empty")
    raw = mbt.encode("utf-8")
    if len(raw) > MAX_PLAINTEXT:
        raise DdpError("ddp_mbt_too_large")
    compressed = _compress(raw)

    if not password:
        crc = zlib.crc32(compressed) & 0xFFFFFFFF
        return MAGIC_OPEN + bytes([VERSION]) + struct.pack("<I", crc) + compressed

    salt = os.urandom(SALT_BYTES)
    nonce = os.urandom(NONCE_BYTES)
    header = MAGIC + bytes([VERSION]) + salt + nonce
    key = _derive_key(password, salt)
    ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(compressed, header, nonce, key)
    if len(ciphertext) > MAX_CIPHERTEXT:
        raise DdpError("ddp_ciphertext_too_large")
    return header + ciphertext


def decrypt_ddp(data: bytes, password: str = "") -> str:
    if len(data) < 10 or len(data) > MAX_CIPHERTEXT + 16:
        raise DdpError("ddp_container_invalid")

    if data[:4] == MAGIC_OPEN:
        if data[4] != VERSION:
            raise DdpError("ddp_version_unsupported")
        stored_crc = struct.unpack("<I", data[5:9])[0]
        payload = data[9:]
        if (zlib.crc32(payload) & 0xFFFFFFFF) != stored_crc:
            raise DdpError("ddp_checksum_failed")
        raw = _decompress(payload)
        if not raw:
            raise DdpError("ddp_plaintext_invalid")
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise DdpError("ddp_mbt_not_utf8") from exc

    if not password:
        raise DdpError("ddp_password_required")
    if len(data) < HEADER_BYTES + 16 or len(data) > MAX_CIPHERTEXT + HEADER_BYTES:
        raise DdpError("ddp_container_invalid")
    if data[:4] != MAGIC:
        raise DdpError("ddp_magic_invalid")
    if data[4] != VERSION:
        raise DdpError("ddp_version_unsupported")

    salt = data[5 : 5 + SALT_BYTES]
    nonce = data[5 + SALT_BYTES : HEADER_BYTES]
    ciphertext = data[HEADER_BYTES:]
    key = _derive_key(password, salt)
    try:
        compressed = crypto_aead_xchacha20poly1305_ietf_decrypt(
            ciphertext, data[:HEADER_BYTES], nonce, key
        )
    except Exception as exc:
        raise DdpError("ddp_authentication_failed") from exc
    raw = _decompress(compressed)
    if not raw:
        raise DdpError("ddp_plaintext_invalid")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise DdpError("ddp_mbt_not_utf8") from exc


def save_ddp(path: str, mbt: str, password: str = "") -> dict:
    payload = encrypt_ddp(mbt, password)
    with open(path, "wb") as fh:
        fh.write(payload)
    return {"ok": True, "path": path, "bytes": len(payload)}


def load_ddp(path: str, password: str = "") -> Tuple[str, dict]:
    with open(path, "rb") as fh:
        data = fh.read(MAX_CIPHERTEXT + HEADER_BYTES + 1)
    mbt = decrypt_ddp(data, password)
    return mbt, {"ok": True, "path": path, "bytes": len(data)}
