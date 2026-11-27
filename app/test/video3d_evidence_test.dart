// 3D 视频帧证据的解码与上限（纯 Dart，不碰文件/WebView）。
//
// 覆盖四组：
//  1. 合法 PNG data URL → 字节 + 魔数；
//  2. 非 PNG / 空载荷 / 坏 base64 / 假 PNG → 各自的稳定失败码；
//  3. 单帧上限；
//  4. 一次取证的帧数预算。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video3d/video3d_evidence.dart';

/// 69 字节的合法 1×1 PNG（IHDR + IDAT + IEND）。
const String _pngBase64 =
    'iVBORw0KGgpJSERSAAAADQAAAAEAAAABCAIAAACQd1PeSURBVAAAAAx4nGNgYGAAAAAEAAH2FzhV'
    'SUVORAAAAACuQmCC';

String _dataUrl(String base64) => 'data:image/png;base64,$base64';

Video3dFrameEvidence _frame(int index, {int bytes = 69}) => Video3dFrameEvidence(
  frame: index,
  bytes: Uint8List(bytes),
  renderer: 'webgl_three_r160',
);

void main() {
  group('解码', () {
    test('合法 PNG data URL → 字节与魔数都对', () {
      final Uint8List bytes = decodeVideo3dEvidenceDataUrl(
        _dataUrl(_pngBase64),
      );
      expect(bytes.length, 69);
      expect(bytes[0], 0x89);
      expect(bytes[1], 0x50);
      expect(bytes[2], 0x4E);
      expect(bytes[3], 0x47);
    });

    test('非 PNG 前缀：显性拒绝（不猜格式）', () {
      expect(
        () => decodeVideo3dEvidenceDataUrl('data:image/jpeg;base64,AAAA'),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceFormatCode,
          ),
        ),
      );
      expect(
        () => decodeVideo3dEvidenceDataUrl(''),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceFormatCode,
          ),
        ),
      );
    });

    test('空载荷：显性空证据码（不产出空白 PNG）', () {
      expect(
        () => decodeVideo3dEvidenceDataUrl(_dataUrl('')),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceEmptyCode,
          ),
        ),
      );
    });

    test('坏 base64：显性格式错误', () {
      expect(
        () => decodeVideo3dEvidenceDataUrl(_dataUrl('!!!!')),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceFormatCode,
          ),
        ),
      );
    });

    test('base64 合法但不是 PNG（魔数不符）：拒绝写盘', () {
      // 'AAAA' 解出来 3 个 0x00 字节，不是 PNG。
      expect(
        () => decodeVideo3dEvidenceDataUrl(_dataUrl('AAAA')),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceFormatCode,
          ),
        ),
      );
    });

    test('单帧上限：超限显性失败（不静默截断）', () {
      expect(
        () => decodeVideo3dEvidenceDataUrl(_dataUrl(_pngBase64), maxBytes: 32),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceTooLargeCode,
          ),
        ),
      );
    });
  });

  group('预算', () {
    test('帧数超上限 → limit 码', () {
      final List<Video3dFrameEvidence> tooMany = <Video3dFrameEvidence>[
        for (int i = 0; i <= video3dEvidenceMaxFrames; i++) _frame(i),
      ];
      expect(
        () => checkVideo3dEvidenceBudget(tooMany),
        throwsA(
          isA<Video3dEvidenceError>().having(
            (e) => e.code,
            'code',
            video3dEvidenceLimitCode,
          ),
        ),
      );
    });

    test('帧数与总量都在限内 → 通过', () {
      expect(
        () => checkVideo3dEvidenceBudget(<Video3dFrameEvidence>[
          _frame(0),
          _frame(150),
        ]),
        returnsNormally,
      );
    });
  });
}
