// DDP codec contract (batch 03).
//
// The binary fixtures under `test/fixtures/ddp/` were produced by the Rust /
// Python authority (`vendor/moonviz-ddp` semantics). Two directions are
// locked here:
//
//  * every reference container decrypts in Dart to the expected document;
//  * re-encrypting with the same parameters reproduces the container
//    **byte-for-byte** (DDP2 is deterministic; DDP1 only with a fixed
//    salt/nonce, which is why the codec exposes those for tests and the
//    production path uses secure random material).
//
// Malicious containers (zstd bomb, oversized window, oversized plaintext,
// oversized container, truncated frame, CRC mismatch, wrong password) must
// all fail closed with the same internal codes the reference host uses.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/ddp.dart';

Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

File _fixture(String name) => File('${_packageRoot().path}/test/fixtures/ddp/$name');

Uint8List _bytes(String name) => _fixture(name).readAsBytesSync();

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _fixedPassword = 'correct horse battery staple';

Uint8List _fixedSalt() => Uint8List.fromList(List<int>.generate(DdpCodec.saltBytes, (i) => i));

Uint8List _fixedNonce() => Uint8List.fromList(List<int>.generate(DdpCodec.nonceBytes, (i) => i));

void main() {
  group('fixtures', () {
    test('manifest hashes match the committed containers', () async {
      final manifest =
          jsonDecode(_fixture('manifest.json').readAsStringSync()) as Map<String, dynamic>;
      expect(manifest, isNotEmpty);
      for (final entry in manifest.entries) {
        final bytes = _fixture(entry.key).readAsBytesSync();
        final digest = await Sha256().hash(bytes);
        final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(hex, (entry.value as Map)['container_sha256'], reason: entry.key);
      }
    });
  });

  group('reference containers decrypt and re-encrypt byte-for-byte', () {
    final fixtures = <String, String>{
      'ddp2_rand1024.ddp': '',
      'ddp2_rand65536.ddp': '',
      'ddp2_text1320k.ddp': '',
      'ddp2_mixed5296.ddp': '',
      'ddp1_fixed.ddp': _fixedPassword,
    };

    fixtures.forEach((name, password) {
      test(name, () async {
        final container = _bytes(name);
        final document = await DdpCodec.decrypt(container, password: password);
        expect(document, isNotEmpty);

        final isLocked = name.startsWith('ddp1_');
        final rebuilt = await DdpCodec.encrypt(
          document,
          password: password,
          salt: isLocked ? _fixedSalt() : null,
          nonce: isLocked ? _fixedNonce() : null,
        );
        expect(
          _sameBytes(rebuilt, container),
          isTrue,
          reason: '$name did not reproduce the reference bytes',
        );
      });
    });

    test('DDP1 fixed fixture carries the source document verbatim', () async {
      final document = await DdpCodec.decrypt(_bytes('ddp1_fixed.ddp'), password: _fixedPassword);
      expect(document, _fixture('ddp1_fixed.plain.txt').readAsStringSync());
    });

    test('DDP2 is passwordless and DDP1 requires the password', () async {
      final open = _bytes('ddp2_rand1024.ddp');
      expect(DdpCodec.looksLikeDdp(open), isTrue);
      expect(await DdpCodec.decrypt(open), isNotEmpty);

      final locked = _bytes('ddp1_fixed.ddp');
      await expectLater(
        DdpCodec.decrypt(locked),
        throwsA(isA<DdpException>().having((e) => e.code, 'code', 'ddp_password_required')),
      );
      await expectLater(
        DdpCodec.decrypt(locked, password: 'not the password'),
        throwsA(isA<DdpException>().having((e) => e.code, 'code', 'ddp_authentication_failed')),
      );
    });

    test('independent DDP1 writes differ (random salt/nonce, by design)', () async {
      const document = '# 画板\n\n正文。\n';
      final first = await DdpCodec.encrypt(document, password: 'pw');
      final second = await DdpCodec.encrypt(document, password: 'pw');
      expect(_sameBytes(first, second), isFalse);
      expect(await DdpCodec.decrypt(first, password: 'pw'), document);
      expect(await DdpCodec.decrypt(second, password: 'pw'), document);
    });
  });

  group('DDP2 container layout', () {
    test('magic, version, CRC32 and zstd payload', () async {
      final container = _bytes('ddp2_mixed5296.ddp');
      expect(container.sublist(0, 4), DdpCodec.magicOpen);
      expect(container[4], DdpCodec.version);
      final crc = container[5] | (container[6] << 8) | (container[7] << 16) | (container[8] << 24);
      final payload = container.sublist(9);
      expect(crc, _crc32(payload));
      expect(await DdpCodec.decrypt(container), isNotEmpty);
    });

    test('unicode and quotes round-trip without escaping loss', () async {
      const document = '---\nmoonviz:\n  revision: 1\n---\n\n# 画板 “引号” & <tag>\n\n内容 → 结束\n';
      final container = await DdpCodec.encrypt(document);
      expect(await DdpCodec.decrypt(container), document);
    });
  });

  group('malicious or broken containers fail closed', () {
    Future<void> expectCode(String fixture, String code, {String password = ''}) async {
      await expectLater(
        DdpCodec.decrypt(_bytes(fixture), password: password),
        throwsA(isA<DdpException>().having((e) => e.code, 'code', code)),
        reason: fixture,
      );
    }

    test('zstd bomb (9 MiB decoded) is rejected after the 8 MiB cap', () async {
      await expectCode('bomb_9mib.ddp', 'ddp_plaintext_invalid');
    });

    test('exactly 8 MiB + 1 decoded bytes is rejected', () async {
      await expectCode('plain_8mib_plus1.ddp', 'ddp_plaintext_invalid');
    });

    test('frame declaring a window above 2^23 is rejected', () async {
      await expectCode('window_gt_23.ddp', 'ddp_plaintext_invalid');
    });

    test('CRC mismatch is rejected before decompression', () async {
      await expectCode('crc_error.ddp', 'ddp_checksum_failed');
    });

    test('truncated DDP1 frame fails authentication', () async {
      await expectCode('truncated.ddp', 'ddp_authentication_failed', password: _fixedPassword);
    });

    test('truncated zstd frame (valid CRC) fails decompression', () async {
      await expectCode('truncated_frame.ddp', 'ddp_decompression_failed');
    });

    test('unsupported version', () async {
      await expectCode('version_unsupported.ddp', 'ddp_version_unsupported');
    });

    test('unknown magic with a password', () async {
      await expectCode('magic_invalid.ddp', 'ddp_magic_invalid', password: 'pw');
    });

    test('payload that is not UTF-8', () async {
      await expectCode('not_utf8.ddp', 'ddp_mbt_not_utf8');
    });

    test('too short to be a container', () async {
      await expectCode('short.ddp', 'ddp_container_invalid');
    });

    test('16 MiB + 46 byte container is rejected before any parsing', () async {
      final oversized = Uint8List(DdpCodec.maxCiphertextBytes + DdpCodec.headerBytes + 1);
      oversized.setAll(0, DdpCodec.magicLocked);
      oversized[4] = DdpCodec.version;
      await expectLater(
        DdpCodec.decrypt(oversized, password: 'pw'),
        throwsA(isA<DdpException>().having((e) => e.code, 'code', 'ddp_container_invalid')),
      );
    });

    test('wrong password is indistinguishable from tampering', () async {
      final locked = _bytes('ddp1_fixed.ddp');
      final tampered = Uint8List.fromList(locked);
      tampered[tampered.length - 1] ^= 0x40;
      for (final candidate in [locked, tampered]) {
        await expectLater(
          DdpCodec.decrypt(candidate, password: 'wrong password'),
          throwsA(isA<DdpException>().having((e) => e.code, 'code', 'ddp_authentication_failed')),
        );
      }
    });
  });

  group('writer bounds', () {
    test('empty documents are rejected', () async {
      await expectLater(
        DdpCodec.encrypt(''),
        throwsA(isA<DdpException>().having((e) => e.code, 'code', 'ddp_mbt_empty')),
      );
    });

    test('plaintext above 8 MiB is rejected before compression', () async {
      final oversized = List.filled(DdpCodec.maxPlaintextBytes + 1, 'x').join();
      await expectLater(
        DdpCodec.encrypt(oversized),
        throwsA(isA<DdpException>().having((e) => e.code, 'code', 'ddp_mbt_too_large')),
      );
    });

    test('exactly 8 MiB is accepted and round-trips', () async {
      final document = List.filled(DdpCodec.maxPlaintextBytes, 'y').join();
      final container = await DdpCodec.encrypt(document);
      expect(await DdpCodec.decrypt(container), document);
    });

    test('fixed salt/nonce arguments are validated', () async {
      await expectLater(
        DdpCodec.encrypt('x', password: 'pw', salt: Uint8List(8)),
        throwsArgumentError,
      );
      await expectLater(
        DdpCodec.encrypt('x', password: 'pw', nonce: Uint8List(8)),
        throwsArgumentError,
      );
    });
  });
}

/// Local CRC32 so the test does not reach into private codec internals.
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
