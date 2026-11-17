// 纯 Dart SHA-256 的标准测试向量回归（N6/M1 模型校验的密码学原语）。
//
// 为什么有这份文件：模型下载的 sha256 校验不能依赖传递依赖（crypto 不是本仓
// 直接依赖），实现是手写的——手写密码学必须有已知答案向量锚定，否则「能跑
// 但不正确」是最危险的状态。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/sha256_digest.dart';

void main() {
  group('sha256Hex 标准向量（FIPS 180-4）', () {
    final cases = <String, String>{
      '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      // 56 字节：正好触发「padding 跨块」边界（0x80 + 8 字节长度需要两块）。
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq':
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    };
    cases.forEach((input, expected) {
      test('${input.isEmpty ? '空串' : '${input.length}B'} → $expected', () {
        expect(sha256Hex(input.codeUnits), expected);
      });
    });

    test('100 万字节 "a"', () {
      final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
      expect(
        sha256Hex(million),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });

  group('Sha256Digest 增量语义', () {
    test('任意切块与一次喂入结果一致', () {
      final data = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
      final once = sha256Hex(data);
      final digest = Sha256Digest();
      var offset = 0;
      for (final step in const [1, 7, 63, 64, 65, 129, 233]) {
        final end = (offset + step) > data.length ? data.length : offset + step;
        digest.add(data.sublist(offset, end));
        offset = end;
        if (offset == data.length) break;
      }
      if (offset < data.length) digest.add(data.sublist(offset));
      expect(digest.close(), once);
    });

    test('close 之后 add 抛 StateError', () {
      final digest = Sha256Digest()..add([1, 2, 3]);
      digest.close();
      expect(() => digest.add([4]), throwsStateError);
      expect(() => digest.close(), throwsStateError);
    });
  });

  group('sha256File 流式', () {
    test('与内存摘要一致（含 64KiB 分块边界）', () async {
      final dir = await Directory.systemTemp.createTemp('sha256_file_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/blob.bin');
      final bytes = Uint8List.fromList(List<int>.generate(200000, (i) => (i * 31) % 256));
      await file.writeAsBytes(bytes);
      expect(await sha256File(file), sha256Hex(bytes));
    });

    test('空文件', () async {
      final dir = await Directory.systemTemp.createTemp('sha256_empty_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/empty.bin');
      await file.writeAsBytes(const []);
      expect(
        await sha256File(file),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });
}
