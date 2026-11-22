// 动效合成（HTML/CSS/JS 短片）数据面的纯函数测试。
//
// 覆盖：
//  ① `parseVideoClips`：正常清单、顺序即数组顺序（乱序 id 不重排）、坏条目
//     跳过不崩、坏 JSON / 非数组返回空表、重复 id 只留第一条；
//  ② `VideoClipInfo.fromJson`：缺字段抛 FormatException（严格解析入口）；
//  ③ `assembleVideoClipHtml`：engine.css 落在 `</head>` 前、engine.js 落在
//     `</body>` 前；无闭合标签的页面走兜底并且引擎在短片脚本之前；重复调用
//     幂等（不重复注入引擎）。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video_clip.dart';

const _engineCss = '/* engine css */ :root { --ink: #26262b; }';
const _engineJs = '/* engine js */ window.ND = window.ND || {};';

const _fullPage = '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <title>样例</title>
  <style>#nd-stage { background: var(--paper); }</style>
</head>
<body>
  <div id="nd-viewport"><div id="nd-stage"></div></div>
  <script>
    (function () {
      function render(t) {}
      ND.scene({ duration: 4.0, render: render });
    })();
  </script>
</body>
</html>
''';

/// 现有短片的骨架：没有 `</head>` / `</body>` / `<html>`，脚本直接写在末尾。
const _barePage = '''
<style>
  #nd-stage { background: #f6efe1; }
</style>
<div id="nd-viewport"><div id="nd-stage"></div></div>
<script>
  (function () {
    function render(t) {}
    ND.scene({ duration: 6.0, render: render });
  })();
</script>
''';

void main() {
  group('parseVideoClips', () {
    test('正常清单：字段齐全，顺序即数组顺序', () {
      final clips = parseVideoClips('''
      [
        {
          "id": "sketch-friction",
          "title": "摩擦力 · 简笔演示",
          "subtitle": "手绘纸面 + 逐笔描线 + 数值滚动",
          "style": "hand",
          "duration": 13.2,
          "file": "sketch-friction.html",
          "tags": ["简笔", "物理"]
        },
        {
          "id": "type-launch",
          "title": "排版 · 标题落位",
          "subtitle": "字号与字距的层次",
          "style": "motion",
          "duration": 9,
          "tags": ["动效排版"]
        }
      ]
      ''');

      expect(clips, hasLength(2));
      expect(clips[0].id, 'sketch-friction');
      expect(clips[0].title, '摩擦力 · 简笔演示');
      expect(clips[0].subtitle, '手绘纸面 + 逐笔描线 + 数值滚动');
      expect(clips[0].style, 'hand');
      expect(clips[0].duration, 13.2);
      expect(clips[0].file, 'sketch-friction.html');
      expect(clips[0].tags, ['简笔', '物理']);

      // file 缺省 = <id>.html；tags 缺省为空；duration 整数也接受。
      expect(clips[1].file, 'type-launch.html');
      expect(clips[1].tags, ['动效排版']);
      expect(clips[1].duration, 9.0);
      expect(clips[1].style, 'motion');
    });

    test('乱序 id 不重排：注入假清单，4 条顺序与数组一致', () {
      const raw = '''
      [
        {"id": "c-third", "title": "第三条", "subtitle": "s3", "duration": 3, "tags": ["t3"]},
        {"id": "a-first", "title": "第一条", "subtitle": "s1", "duration": 1, "tags": ["t1"]},
        {"id": "d-fourth", "title": "第四条", "subtitle": "s4", "duration": 4, "tags": ["t4"]},
        {"id": "b-second", "title": "第二条", "subtitle": "s2", "duration": 2, "tags": ["t2"]}
      ]
      ''';
      final clips = parseVideoClips(raw);
      expect(clips, hasLength(4));
      expect(clips.map((c) => c.id).toList(), ['c-third', 'a-first', 'd-fourth', 'b-second']);
      expect(clips.map((c) => c.title).toList(), ['第三条', '第一条', '第四条', '第二条']);
    });

    test('坏条目跳过不崩：缺字段 / 非对象 / 时长非法 / 重复 id', () {
      const raw = '''
      [
        {"id": "ok-1", "title": "好的", "duration": 2.5},
        null,
        42,
        {"title": "缺 id", "duration": 3},
        {"id": "", "title": "空 id", "duration": 3},
        {"id": "no-title", "duration": 3},
        {"id": "bad-duration", "title": "时长非数值", "duration": "abc"},
        {"id": "negative-duration", "title": "负时长", "duration": -1},
        {"id": "ok-1", "title": "重复 id", "duration": 9},
        {"id": "ok-2", "title": "好的二", "duration": 0, "style": "unknown-style"}
      ]
      ''';
      final clips = parseVideoClips(raw);
      expect(clips, hasLength(2));
      expect(clips[0].id, 'ok-1');
      expect(clips[0].title, '好的', reason: '重复 id 保留第一条');
      expect(clips[1].id, 'ok-2');
      expect(clips[1].style, 'hand', reason: '未知风格归一化到默认值');
    });

    test('坏 JSON / 非数组：返回空表而不是抛栈', () {
      expect(parseVideoClips('not json at all'), isEmpty);
      expect(parseVideoClips('{"id": "x"}'), isEmpty);
      expect(parseVideoClips(''), isEmpty);
    });

    test('fromJson 严格解析：缺字段抛 FormatException', () {
      expect(
        () => VideoClipInfo.fromJson(<String, dynamic>{'id': 'x', 'title': 't'}),
        throwsFormatException,
      );
      expect(
        VideoClipInfo.fromJson(<String, dynamic>{
          'id': 'x',
          'title': 't',
          'duration': 1,
        }).file,
        'x.html',
      );
    });
  });

  group('assembleVideoClipHtml', () {
    test('engine.css 在 </head> 前、engine.js 在 </body> 前', () {
      final html = assembleVideoClipHtml(
        engineCss: _engineCss,
        engineJs: _engineJs,
        clipHtml: _fullPage,
      );

      final cssAt = html.indexOf('--ink: #26262b');
      final headEnd = html.indexOf('</head>');
      final titleAt = html.indexOf('<title>');
      expect(cssAt, greaterThan(titleAt), reason: '注入在 head 末尾，短片自带样式之后');
      expect(cssAt, lessThan(headEnd));

      final jsAt = html.indexOf('window.ND = window.ND || {}');
      final clipScriptAt = html.indexOf('ND.scene({ duration: 4.0');
      final bodyEnd = html.indexOf('</body>');
      expect(jsAt, greaterThan(0));
      expect(jsAt, lessThan(bodyEnd), reason: 'JS 注入点固定在 </body> 之前（契约 §2）');
      // 契约注入顺序固定：短片脚本写在 DOMContentLoaded 里才调 ND.scene，
      // 所以即使页面 <script> 在注入点之前执行也安全，不额外挪动引擎。
      expect(clipScriptAt, lessThan(jsAt));
    });

    test('重复调用幂等：已有引擎标记就不重复注入', () {
      final once = assembleVideoClipHtml(
        engineCss: _engineCss,
        engineJs: _engineJs,
        clipHtml: _fullPage,
      );
      final twiceOnAssembled = assembleVideoClipHtml(
        engineCss: _engineCss,
        engineJs: _engineJs,
        clipHtml: once,
      );
      expect(twiceOnAssembled, once, reason: '对已装配页面再装配必须原样返回');

      final twiceFromSource = assembleVideoClipHtml(
        engineCss: _engineCss,
        engineJs: _engineJs,
        clipHtml: _fullPage,
      );
      expect(twiceFromSource, once, reason: '同样的输入必须得到同样的单文件');

      expect(RegExp(r'data-nd-engine="css"').allMatches(once).length, 1);
      expect(RegExp(r'data-nd-engine="js"').allMatches(once).length, 1);
      expect('--ink: #26262b'.allMatches(once).length, 1);
      expect('window.ND = window.ND || {}'.allMatches(once).length, 1);
    });

    test('没有 head/body 锚点的页面：兜底注入且引擎仍在短片脚本之前', () {
      final html = assembleVideoClipHtml(
        engineCss: _engineCss,
        engineJs: _engineJs,
        clipHtml: _barePage,
      );
      expect(html, contains('--ink: #26262b'));
      expect(html, contains('window.ND = window.ND || {}'));
      expect(
        html.indexOf('window.ND = window.ND || {}'),
        lessThan(html.indexOf('ND.scene({ duration: 6.0')),
        reason: '无 </body> 时引擎兜底到短片脚本之前，加载即调 ND.scene 也不会炸',
      );
    });

    test('空页面也能装配成单文件（不抛异常）', () {
      final html = assembleVideoClipHtml(
        engineCss: _engineCss,
        engineJs: _engineJs,
        clipHtml: '',
      );
      expect(html, contains('--ink: #26262b'));
      expect(html, contains('window.ND = window.ND || {}'));
    });
  });
}
