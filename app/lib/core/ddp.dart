// DDP container codec — pure Dart port of `vendor/moonviz-ddp` (Rust), which
// is the authority for `.ddp` byte layout. (The former Python test oracle
// `server/ddp.py` was removed with the de-Python migration, batch 15 — the
// Rust crate is the only authority now.) Nothing here talks to Python or a
// server.
//
// One `.ddp` is the authenticated representation of exactly one source
// document (the canonical `.mbt.md` text):
//
//   DDP1  password:    zstd(payload) → XChaCha20-Poly1305, AAD = clear header
//   DDP2  passwordless: zstd(payload) + CRC32
//
// Argon2id parameters match the Rust crate: m = 19 * 1024 KiB, t = 2, p = 1,
// 32-byte key, version 0x13 (19). zstd level 8, window cap 2^23, output cap
// 8 MiB — the same bounds the Rust host applies, so a container accepted here
// is accepted there and vice versa.
//
// Failure codes are the stable internal names the rest of the app already
// knows (`ddp_password_required`, `ddp_authentication_failed`, …). They are
// never shown to users directly; UI copy maps them through the glossary.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

/// Thrown when a container cannot be written or opened.
///
/// [code] is an internal, stable identifier (see the file header). Callers
/// decide how to surface it; the default `toString()` is the code itself so
/// logs stay terse.
class DdpException implements Exception {
  /// Stable internal code.
  final String code;

  /// Optional diagnostic detail (never user-visible).
  final String? detail;

  const DdpException(this.code, [this.detail]);

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

/// DDP1/DDP2 container codec.
///
/// All methods are static and pure: they take bytes in, return bytes out, and
/// never touch the filesystem. `ProjectService` owns persistence.
class DdpCodec {
  DdpCodec._();

  /// Container format version written by this codec.
  static const int version = 1;

  static const int saltBytes = 16;
  static const int nonceBytes = 24;

  /// `MAGIC(4) + version(1) + salt(16) + nonce(24)`.
  static const int headerBytes = 4 + 1 + saltBytes + nonceBytes;

  /// Maximum accepted payload (UTF-8 source bytes), matching the Rust crate.
  static const int maxPlaintextBytes = 8 * 1024 * 1024;

  /// Maximum accepted ciphertext (excluding the 45-byte DDP1 header).
  static const int maxCiphertextBytes = 16 * 1024 * 1024;

  /// zstd level used by the reference implementation.
  static const int zstdLevel = 8;

  /// zstd window log cap. Frames declaring a wider window are rejected before
  /// any buffer is allocated for them (decompression-bomb guard).
  static const int maxWindowLog = 23;

  /// Passwordless container magic.
  static const List<int> magicOpen = [0x44, 0x44, 0x50, 0x32]; // DDP2

  /// Password container magic.
  static const List<int> magicLocked = [0x44, 0x44, 0x50, 0x31]; // DDP1

  // Argon2id parameters — the Rust crate's `Params::new(19 * 1024, 2, 1, 32)`.
  static const int _argonMemoryKiB = 19 * 1024;
  static const int _argonIterations = 2;
  static const int _argonParallelism = 1;
  static const int _argonHashLength = 32;

  /// True when [data] starts with either DDP magic.
  static bool looksLikeDdp(List<int> data) {
    if (data.length < 4) return false;
    for (final magic in const [magicLocked, magicOpen]) {
      var match = true;
      for (var i = 0; i < 4; i++) {
        if (data[i] != magic[i]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  /// Encrypts [document] into a DDP container.
  ///
  /// Empty [password] writes DDP2 (zstd + CRC32, opens without a password);
  /// any other password writes DDP1 (Argon2id + XChaCha20-Poly1305).
  ///
  /// [salt] / [nonce] exist only so tests can reproduce a fixed fixture
  /// byte-for-byte. Production calls must leave them null: a fixed salt or
  /// nonce would repeat key material and void the encryption.
  static Future<Uint8List> encrypt(
    String document, {
    String password = '',
    Uint8List? salt,
    Uint8List? nonce,
  }) async {
    if (document.isEmpty) {
      throw const DdpException('ddp_mbt_empty');
    }
    final raw = Uint8List.fromList(utf8.encode(document));
    if (raw.length > maxPlaintextBytes) {
      throw const DdpException('ddp_mbt_too_large');
    }
    final compressed = _compress(raw);

    if (password.isEmpty) {
      final header = BytesBuilder(copy: false)
        ..add(magicOpen)
        ..addByte(version)
        ..add(_u32le(_crc32(compressed)));
      header.add(compressed);
      return header.toBytes();
    }

    final saltBytesUsed = salt ?? _randomBytes(DdpCodec.saltBytes);
    final nonceBytesUsed = nonce ?? _randomBytes(DdpCodec.nonceBytes);
    if (saltBytesUsed.length != DdpCodec.saltBytes) {
      throw ArgumentError.value(saltBytesUsed.length, 'salt', 'must be 16 bytes');
    }
    if (nonceBytesUsed.length != DdpCodec.nonceBytes) {
      throw ArgumentError.value(nonceBytesUsed.length, 'nonce', 'must be 24 bytes');
    }

    final header = BytesBuilder(copy: false)
      ..add(magicLocked)
      ..addByte(version)
      ..add(saltBytesUsed)
      ..add(nonceBytesUsed);
    final aad = header.toBytes();

    final key = await _deriveKey(password, saltBytesUsed);
    final SecretBox box;
    try {
      box = await Xchacha20.poly1305Aead().encrypt(
        compressed,
        secretKey: key,
        nonce: nonceBytesUsed,
        aad: aad,
      );
    } catch (e) {
      throw DdpException('ddp_encryption_failed', '$e');
    }
    final ciphertext = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    if (ciphertext.length > maxCiphertextBytes) {
      throw const DdpException('ddp_ciphertext_too_large');
    }
    return (BytesBuilder(copy: false)
          ..add(aad)
          ..add(ciphertext))
        .toBytes();
  }

  /// Decrypts [data] into the source document.
  ///
  /// Throws [DdpException] with the reference code on every failure path.
  static Future<String> decrypt(
    List<int> data, {
    String password = '',
  }) async {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (bytes.length < 10 || bytes.length > maxCiphertextBytes + 16) {
      throw const DdpException('ddp_container_invalid');
    }

    if (_startsWith(bytes, magicOpen)) {
      if (bytes[4] != version) {
        throw const DdpException('ddp_version_unsupported');
      }
      final storedCrc = _readU32le(bytes, 5);
      final payload = Uint8List.sublistView(bytes, 9);
      if (_crc32(payload) != storedCrc) {
        throw const DdpException('ddp_checksum_failed');
      }
      return _decodePlaintext(_decompress(payload));
    }

    if (password.isEmpty) {
      throw const DdpException('ddp_password_required');
    }
    if (bytes.length < headerBytes + 16 ||
        bytes.length > maxCiphertextBytes + headerBytes) {
      throw const DdpException('ddp_container_invalid');
    }
    if (!_startsWith(bytes, magicLocked)) {
      throw const DdpException('ddp_magic_invalid');
    }
    if (bytes[4] != version) {
      throw const DdpException('ddp_version_unsupported');
    }

    final salt = Uint8List.sublistView(bytes, 5, 5 + saltBytes);
    final nonce = Uint8List.sublistView(bytes, 5 + saltBytes, headerBytes);
    final ciphertext = Uint8List.sublistView(bytes, headerBytes);
    final aad = Uint8List.sublistView(bytes, 0, headerBytes);

    final key = await _deriveKey(password, salt);
    final Uint8List compressed;
    try {
      final clear = await Xchacha20.poly1305Aead().decrypt(
        SecretBox(
          Uint8List.sublistView(ciphertext, 0, ciphertext.length - 16),
          nonce: nonce,
          mac: Mac(Uint8List.sublistView(ciphertext, ciphertext.length - 16)),
        ),
        secretKey: key,
        aad: aad,
      );
      compressed = Uint8List.fromList(clear);
    } catch (e) {
      // Wrong password, tampered header, truncated tag — all indistinguishable
      // by design (authenticated encryption).
      throw const DdpException('ddp_authentication_failed');
    }
    return _decodePlaintext(_decompress(compressed));
  }

  static Future<SecretKey> _deriveKey(String password, Uint8List salt) async {
    try {
      return await Argon2id(
        parallelism: _argonParallelism,
        memory: _argonMemoryKiB,
        iterations: _argonIterations,
        hashLength: _argonHashLength,
      ).deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );
    } catch (e) {
      throw DdpException('ddp_key_derivation_failed', '$e');
    }
  }

  /// zstd level 8 — byte-identical to the reference encoder for the container
  /// shapes the app writes (checked in `test/ddp_test.dart` against fixtures
  /// produced by the Rust/Python authority).
  static Uint8List _compress(Uint8List raw) {
    try {
      return ZstdEncoder(level: zstdLevel).encodeBytes(raw);
    } catch (e) {
      throw DdpException('ddp_compression_failed', '$e');
    }
  }

  /// Streaming-bounded decompression.
  ///
  /// The decoder rejects frames whose advertised window exceeds
  /// [maxWindowLog] and stops once output passes [maxPlaintextBytes] + 1.
  /// Anything malformed (truncated frame, bad block, checksum mismatch) is
  /// `ddp_decompression_failed`; anything that survives but decodes to an
  /// empty or oversized payload is `ddp_plaintext_invalid`.
  static Uint8List _decompress(Uint8List compressed) {
    Uint8List out;
    try {
      out = ZstdDecoder(maxWindowSize: 1 << maxWindowLog).decodeBytes(
        compressed,
        verify: true,
        throwOnError: true,
        // Hard ceiling on allocation: one byte over 8 MiB is rejected by the
        // decoder itself; an exactly-8 MiB payload is still a valid source.
        maxOutputSize: maxPlaintextBytes,
      );
    } on ArchiveLimitException {
      // Either the declared window or the decoded size crossed the cap;
      // both are "the payload is not a valid 8 MiB project source".
      throw const DdpException('ddp_plaintext_invalid');
    } catch (e) {
      throw DdpException('ddp_decompression_failed', '$e');
    }
    if (out.isEmpty || out.length > maxPlaintextBytes) {
      throw const DdpException('ddp_plaintext_invalid');
    }
    return out;
  }

  static String _decodePlaintext(Uint8List raw) {
    try {
      return utf8.decode(raw);
    } catch (e) {
      throw const DdpException('ddp_mbt_not_utf8');
    }
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
  }

  static Uint8List _u32le(int value) => Uint8List(4)
    ..[0] = value & 0xFF
    ..[1] = (value >> 8) & 0xFF
    ..[2] = (value >> 16) & 0xFF
    ..[3] = (value >> 24) & 0xFF;

  static int _readU32le(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static List<int>? _crcTable;

  /// IEEE CRC32 (same polynomial the Rust/Python containers use).
  static int _crc32(Uint8List data) {
    final table = _crcTable ??= List<int>.generate(256, (n) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      return c;
    }, growable: false);
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
