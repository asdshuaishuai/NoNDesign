// Phaser 4 引擎短片播放页：自包含、CSP 关网、字节确定、槽位零残留。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video/video_screenplay.dart';
import 'package:nondesign/core/video/video_short_player.dart';
import 'package:nondesign/core/video/video_style_pack.dart';

const String _phaserStub = 'var Phaser = { VERSION: "4.2.1" };\n';
const String _pixelfxStub =
    'window.NAN_PIXELFX = { effectIds: [], renderInto: function () { return 0; } };\n';

VideoScreenplay _screenplay({List<Object?>? events}) {
  final Map<String, Object?> raw = <String, Object?>{
    'schema': 'nan.screenplay/1',
    'width': 320,
    'height': 180,
    'shots': <Object?>[
      <String, Object?>{
        'id': 's1',
        'start': 0.0,
        'duration': 2.0,
        'events':
            events ??
            <Object?>[
              <String, Object?>{
                'f': 15,
                'type': 'vfx',
                'cue': 'fire.campfire',
                'x': 4,
                'y': 2,
              },
              <String, Object?>{'f': 20, 'type': 'caption'},
            ],
      },
    ],
  };
  final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
  expect(result.verified, isTrue, reason: '${result.toJson()}');
  return result.screenplay!;
}

String _page({
  String phaser = _phaserStub,
  String pixelfx = '',
  List<Object?>? events,
  VideoStylePack? style,
}) => assembleVideoShortPage(
  _screenplay(events: events),
  phaserSource: phaser,
  pixelfxSource: pixelfx,
  stylePack: style,
);

VideoStylePack _stylePack() {
  final VideoStylePackVerification result = verifyVideoStylePack(
    <String, Object?>{
      'schema': 'nan.style_pack/1',
      'id': 'warm',
      'palette': <String, Object?>{
        'background': '#101010',
        'band': '#202020',
        'accent': '#ff8800',
        'text': '#ffffff',
      },
      'typography': <String, Object?>{'caption': 'lg'},
      'motion': <String, Object?>{'progress': 'ease_out'},
    },
    globalVfxAllowlist: videoVfxCueAllowlist,
  );
  expect(result.verified, isTrue, reason: '${result.toJson()}');
  return result.stylePack!;
}

void main() {
  group('页面结构', () {
    test('自包含：CSP 关网、Phaser 内联、桥与命令面齐全', () {
      final String html = _page();
      expect(html, startsWith('<!doctype html>'));
      // CSP 四要素：默认禁、只允许内联、连接禁、数据图片允许。
      expect(html, contains("default-src 'none'"));
      expect(html, contains("script-src 'unsafe-inline'"));
      expect(html, contains("connect-src 'none'"));
      expect(html, contains('img-src data:'));
      expect(html, isNot(contains("connect-src 'self'")));
      // Phaser 原文内联（不是外链）。
      expect(html, contains(_phaserStub.trim()));
      expect(html, contains('var BRIDGE = "NONSHORT"'));
      expect(html, contains('var CONTROLLER = "NONSHORT_PLAYER"'));
      expect(html, contains('window[BRIDGE].postMessage'));
      expect(html, contains('window[CONTROLLER]'));
      expect(html, contains('phaser4_canvas'));
      // 没有 pixelfx 时两个脚本块（运行时 + 页面逻辑），没有半截。
      expect(RegExp('</script', caseSensitive: false).allMatches(html).length, 2);
    });

    test('没有外部资源引用（零 http 外链属性）', () {
      final String html = _page();
      expect(html, isNot(contains('src="http')));
      expect(html, isNot(contains('href="http')));
      expect(html, isNot(contains('fetch(')));
      expect(html, isNot(contains('<link')));
    });

    test('模板槽位全部替换（无占位残留）', () {
      final String html = _page();
      for (final String slot in <String>[
        '/*__CSP__*/',
        '/*__PHASER_SOURCE__*/',
        '/*__TIMELINE_JSON__*/',
        '/*__WIDTH__*/',
        '/*__HEIGHT__*/',
        '/*__RENDERER__*/',
        '/*__BRIDGE_NAME__*/',
        '/*__CONTROLLER_NAME__*/',
      ]) {
        expect(html, isNot(contains(slot)), reason: '槽位未替换：$slot');
      }
    });

    test('编译后的时间表进页面：镜头与事件（含 allowlist cue）', () {
      final String html = _page();
      expect(html, contains('"totalFrames":60'));
      expect(html, contains('"id":"s1"'));
      expect(html, contains('"cue":"fire.campfire"'));
      expect(html, contains('"f":15'));
      expect(html, contains('"f":20'));
      expect(html, contains('"type":"caption"'));
    });
  });

  group('注入纪律', () {
    test('空/空白 Phaser 文本：显性失败（不产出无引擎空页）', () {
      expect(
        () => assembleVideoShortPage(_screenplay(), phaserSource: ''),
        throwsA(
          isA<VideoShortPlayerError>().having(
            (e) => e.code,
            'code',
            videoShortPhaserMissingCode,
          ),
        ),
      );
      expect(
        () => assembleVideoShortPage(_screenplay(), phaserSource: '   '),
        throwsA(isA<VideoShortPlayerError>()),
      );
    });

    test('Phaser 文本里的 </script 被转义，不提前关闭脚本块', () {
      final String html = _page(
        phaser: 'var x = "</script>";\nvar Phaser = {};\n',
      );
      expect(html, isNot(contains('"</script>"')));
      expect(RegExp('</script', caseSensitive: false).allMatches(html).length, 2);
    });

    test('剧本里的结束标签序列被 JSON 转义（不破坏内联脚本）', () {
      final String html = _page(
        events: <Object?>[
          <String, Object?>{'f': 1, 'type': 'caption'},
          <String, Object?>{'f': 2, 'type': 'sfx'},
        ],
      );
      expect(RegExp('</script', caseSensitive: false).allMatches(html).length, 2);
    });
  });

  group('VFX 像素渲染接线', () {
    test('没有 pixelfx 包：如实降级为占位标记（页面明确标识）', () {
      final String html = _page();
      expect(html, contains('var RENDERER_PLACEHOLDER = "placeholder_markers"'));
      expect(html, isNot(contains('<script id="short-pixelfx">')));
      expect(html, contains('function renderFrameMarkers('));
    });

    test('有 pixelfx 包：真像素分支 + Canvas 纹理上屏 + 如实 vfxRenderer', () {
      final String html = _page(pixelfx: _pixelfxStub);
      // 三段脚本块（运行时 + pixelfx + 页面逻辑）。
      expect(RegExp('</script', caseSensitive: false).allMatches(html).length, 3);
      expect(html, contains(_pixelfxStub.trim()));
      expect(html, contains('var RENDERER_PIXELS = "pixelfx_pixels"'));
      expect(html, contains('window.NAN_PIXELFX.renderInto'));
      expect(html, contains("textures.addCanvas('short-pixels'"));
      expect(html, contains('vfxRenderer: function ()'));
      expect(html, contains('function renderFramePixels('));
      // 像素渲染是纯帧号函数：从 t=0 重建实例并推进，不跨帧漂移。
      expect(html, contains('advanceFrames: advance'));
      expect(html, contains('tmpCtx.clearRect'));
    });

    test('pixelfx 文本里的 </script 被转义', () {
      final String html = _page(
        pixelfx: 'var x = "</script>";\nwindow.NAN_PIXELFX = {};\n',
      );
      expect(RegExp('</script', caseSensitive: false).allMatches(html).length, 3);
    });

    test('含 pixelfx 时仍字节确定', () {
      final String a = _page(pixelfx: _pixelfxStub);
      final String b = _page(pixelfx: _pixelfxStub);
      expect(a, b);
    });
  });

  group('风格包（palette / typography / motion）', () {
    test('不传风格包：timeline.style 为 null（页面用内置默认）', () {
      final String html = _page();
      expect(html, contains('"style":null'));
    });

    test('传风格包：id/调色板/动效进页面，页面按数据应用', () {
      final String html = _page(style: _stylePack());
      expect(html, contains('"style":{"schema":"nan.style_pack/1"'));
      expect(html, contains('"id":"warm"'));
      expect(html, contains('"accent":"#ff8800"'));
      expect(html, contains('"progress":"ease_out"'));
      // 页面侧应用逻辑在场（不是只把 JSON 塞进去）。
      expect(html, contains('function applyStyle()'));
      expect(html, contains('function easeProgress(value)'));
      expect(html, contains('STYLE_VFX'));
      // ready 回执如实带风格 id 与被跳过特效数。
      expect(html, contains("style: STYLE ? String(STYLE.id || '') : ''"));
      expect(html, contains('vfx_skipped: SKIPPED_VFX'));
    });

    test('含风格包时仍字节确定；不同风格包产出不同页面', () {
      final String a = _page(style: _stylePack());
      final String b = _page(style: _stylePack());
      expect(a, b);
      final VideoStylePackVerification other = verifyVideoStylePack(
        <String, Object?>{
          'schema': 'nan.style_pack/1',
          'id': 'cool',
          'palette': <String, Object?>{
            'background': '#101020',
            'band': '#202030',
            'accent': '#0088ff',
            'text': '#ffffff',
          },
        },
        globalVfxAllowlist: videoVfxCueAllowlist,
      );
      expect(other.verified, isTrue);
      expect(_page(style: other.stylePack!), isNot(a));
    });
  });

  group('确定性', () {
    test('同输入两次组装字节完全相同', () {
      final String a = _page();
      final String b = _page();
      expect(a, b);
    });

    test('页面帧时钟只用整数帧（不掺 wall clock 到内容里）', () {
      final String html = _page();
      expect(html, contains('FPS'));
      expect(html, contains('TOTAL_FRAMES'));
      expect(html, contains('function clampFrame('));
      // 播放推进按 rAF 时间戳，但**内容**只由帧号决定（renderFrame 只吃帧号）。
      expect(html, contains('function renderFrame(frame)'));
      expect(html, isNot(contains('Date.now')));
    });
  });
}
