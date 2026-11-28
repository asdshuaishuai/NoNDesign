// 引擎短片帧证据：PNG 解码/上限/预算（与 3D 视频同族，但不共用类型）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video/video_short_evidence.dart';

/// 69 字节的合法 1×1 PNG。
const String _pngBase64 =
    'iVBORw0KGgpJSERSAAAADQAAAAEAAAABCAIAAACQd1PeSURBVAAAAAx4nGNgYGAAAAAEAAH2FzhV'
    'SUVORAAAAACuQmCC';

String _dataUrl(String base64) => 'data:image/png;base64,$base64';

VideoShortFrameEvidence _frame(int index, {int bytes = 69}) =>
    VideoShortFrameEvidence(
      frame: index,
      bytes: Uint8List(bytes),
      renderer: 'phaser4_canvas',
      vfx: 'pixelfx_pixels',
    );

void main() {
  group('解码', () {
    test('合法 PNG：字节与魔数都对', () {
      final Uint8List bytes = decodeVideoShortEvidenceDataUrl(
        _dataUrl(_pngBase64),
      );
      expect(bytes.length, 69);
      expect(bytes[0], 0x89);
      expect(bytes[1], 0x50);
      expect(bytes[2], 0x4E);
      expect(bytes[3], 0x47);
    });

    test('非 PNG 前缀 / 空串：显性拒绝', () {
      for (final String url in <String>['data:image/jpeg;base64,AAAA', '']) {
        expect(
          () => decodeVideoShortEvidenceDataUrl(url),
          throwsA(
            isA<VideoShortEvidenceError>().having(
              (VideoShortEvidenceError e) => e.code,
              'code',
              videoShortEvidenceFormatCode,
            ),
          ),
        );
      }
    });

    test('空载荷：显性空证据码', () {
      expect(
        () => decodeVideoShortEvidenceDataUrl(_dataUrl('')),
        throwsA(
          isA<VideoShortEvidenceError>().having(
            (VideoShortEvidenceError e) => e.code,
            'code',
            videoShortEvidenceEmptyCode,
          ),
        ),
      );
    });

    test('坏 base64 与假 PNG（魔数不符）：拒绝', () {
      for (final String payload in <String>['!!!!', 'AAAA']) {
        expect(
          () => decodeVideoShortEvidenceDataUrl(_dataUrl(payload)),
          throwsA(isA<VideoShortEvidenceError>()),
        );
      }
    });

    test('单帧上限：超限显性失败', () {
      expect(
        () => decodeVideoShortEvidenceDataUrl(
          _dataUrl(_pngBase64),
          maxBytes: 32,
        ),
        throwsA(
          isA<VideoShortEvidenceError>().having(
            (VideoShortEvidenceError e) => e.code,
            'code',
            videoShortEvidenceTooLargeCode,
          ),
        ),
      );
    });
  });

  group('预算', () {
    test('帧数超上限：limit 码', () {
      final List<VideoShortFrameEvidence> tooMany =
          <VideoShortFrameEvidence>[
            for (int i = 0; i <= videoShortEvidenceMaxFrames; i++) _frame(i),
          ];
      expect(
        () => checkVideoShortEvidenceBudget(tooMany),
        throwsA(
          isA<VideoShortEvidenceError>().having(
            (VideoShortEvidenceError e) => e.code,
            'code',
            videoShortEvidenceLimitCode,
          ),
        ),
      );
    });

    test('两帧在限内：通过', () {
      expect(
        () => checkVideoShortEvidenceBudget(<VideoShortFrameEvidence>[
          _frame(0),
          _frame(59),
        ]),
        returnsNormally,
      );
    });
  });
}
