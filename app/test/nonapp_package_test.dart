// `.nonapp` 包解析/校验（app/lib/core/nonapp_package.dart）回归。
//
// 覆盖：合法 html / a2ui（数组与 {"messages":[...]} 两种形状）、manifest
// 全字段、渲染器与载荷形状、以及安全门逐项（坏版本/坏 name/id/未知
// renderer/缺载荷/外链 html/条目穿越/超限/坏 zip）各自的稳定 code。
// 服务端权威顺序见 server/nonapp_agent.py；本文件锚定客户端「同序同码」。
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/nonapp_package.dart';

List<int> _zip(Map<String, Object?> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    final bytes = e.value is String ? utf8.encode(e.value as String) : e.value as List<int>;
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}

String _html({String marker = 'marker-α'}) =>
    '<!doctype html><html><head><style>body{background:#111;color:#eee}'
    'canvas{display:block;width:100%;height:60vh}</style></head>'
    '<body><canvas id=c></canvas><div>$marker</div>'
    '<script>const c=document.getElementById("c");const x=c.getContext("2d");'
    'function f(){x.clearRect(0,0,9,9);requestAnimationFrame(f);}f();</script></body></html>';

Map<String, Object?> _manifest({
  Object? formatVersion = 1,
  Object? id = 'demo-app',
  Object? name = 'demo-app',
  Object? title = '演示应用',
  Object? renderer = 'html',
  Object? createdAt = 1700000000,
  Object? minAppVersion = '0.1.0',
}) =>
    {
      'formatVersion': formatVersion,
      'id': id,
      'name': name,
      'title': title,
      'renderer': renderer,
      'createdAt': createdAt,
      'minAppVersion': minAppVersion,
    };

List<int> _pkg(Map<String, Object?> extra, {Map<String, Object?>? manifest}) => _zip({
      'manifest.json': jsonEncode(manifest ?? _manifest()),
      ...extra,
    });

// createSurface + surfaceUpdate：自足的最小 A2UI v1.0 序列。
final List<Object?> _messages = [
  {
    'version': '1.0',
    'createSurface': {
      'surfaceId': 'demo',
      'catalogId': 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
      'components': [
        {'id': 'root', 'component': 'Column', 'children': ['title']},
        {'id': 'title', 'component': 'Text', 'text': '清单'},
      ],
    },
  },
  {
    'version': '1.0',
    'surfaceUpdate': {'surfaceId': 'demo', 'components': []},
  },
];

void _expectCode(String expected, List<int> bytes, {String? clientVersion}) {
  try {
    NonAppPackage.parse(bytes, clientVersion: clientVersion ?? nonAppClientVersion);
    fail('期望 NonAppException($expected)，实际解析成功');
  } on NonAppException catch (e) {
    expect(e.code, startsWith(expected), reason: 'code=${e.code} message=${e.message}');
  }
}

void main() {
  test('html 包：manifest 全字段 + 载荷字节', () {
    final pkg = NonAppPackage.parse(_pkg({'payload/index.html': _html()}, manifest: {
      ..._manifest(),
      'brief': '一句话',
    }));
    expect(pkg.renderer, 'html');
    expect(pkg.manifest.formatVersion, 1);
    expect(pkg.manifest.id, 'demo-app');
    expect(pkg.manifest.name, 'demo-app');
    expect(pkg.manifest.title, '演示应用');
    expect(pkg.manifest.createdAt, 1700000000);
    expect(pkg.manifest.minAppVersion, '0.1.0');
    expect(pkg.manifest.brief, '一句话');
    expect(utf8.decode(pkg.htmlBytes!), contains('marker-α'));
    expect(pkg.messages, isNull);
  });

  test('a2ui 包：数组与 {"messages":[...]} 两种形状都归一为数组', () {
    final asArray = NonAppPackage.parse(_pkg({
      'payload/surface.json': jsonEncode(_messages),
      'payload/data.json': jsonEncode({'items': <Object>[]}),
    }, manifest: _manifest(renderer: 'a2ui')));
    expect(asArray.renderer, 'a2ui');
    expect(asArray.messages, hasLength(2));
    expect(asArray.data, {'items': <Object>[]});

    final wrapped = NonAppPackage.parse(_pkg({
      'payload/surface.json': jsonEncode({'messages': _messages}),
    }, manifest: _manifest(renderer: 'a2ui')));
    expect(wrapped.messages, hasLength(2));
    expect(wrapped.data, isNull);
  });

  test('a2ui 可选 prompt.txt 保留、超 8KiB 拒绝', () {
    final pkg = NonAppPackage.parse(_pkg({
      'payload/surface.json': jsonEncode(_messages),
      'payload/prompt.txt': '续跑提示',
    }, manifest: _manifest(renderer: 'a2ui')));
    expect(pkg.prompt, '续跑提示');

    _expectCode(
      'nonapp_invalid_prompt',
      _pkg({
        'payload/surface.json': jsonEncode(_messages),
        'payload/prompt.txt': 'x' * (nonAppMaxPromptBytes + 1),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
  });

  test('目录项可容忍（无目录项亦可），未列名条目拒绝', () {
    final archive = Archive();
    archive.addFile(ArchiveFile('manifest.json', 1, utf8.encode(jsonEncode(_manifest()))));
    archive.addFile(ArchiveFile('payload/', 0, const <int>[]));
    archive.addFile(ArchiveFile('payload/index.html', 1, utf8.encode(_html())));
    final ok = NonAppPackage.parse(ZipEncoder().encode(archive)!);
    expect(ok.renderer, 'html');

    _expectCode(
      'nonapp_unexpected_entry:payload/evil.js',
      _pkg({'payload/evil.js': 'x'}),
    );
    _expectCode('nonapp_unexpected_entry:../evil.txt', _pkg({'../evil.txt': 'x'}));
    _expectCode('nonapp_unexpected_entry:/etc/passwd', _pkg({'/etc/passwd': 'x'}));
  });

  test('坏版本 / 坏 id / 坏 name / 未知 renderer / 坏 createdAt', () {
    _expectCode(
      'nonapp_unsupported_version:2',
      _pkg({'payload/index.html': _html()}, manifest: _manifest(formatVersion: 2)),
    );
    _expectCode(
      'nonapp_invalid_id:Bad/Id',
      _pkg({'payload/index.html': _html()}, manifest: _manifest(id: 'Bad/Id')),
    );
    _expectCode(
      'nonapp_invalid_name:bad name',
      _pkg({'payload/index.html': _html()}, manifest: _manifest(name: 'bad name')),
    );
    _expectCode(
      'nonapp_unsupported_renderer:web',
      _pkg({'payload/index.html': _html()}, manifest: _manifest(renderer: 'web')),
    );
    _expectCode(
      'nonapp_invalid_manifest',
      _pkg({'payload/index.html': _html()}, manifest: _manifest(createdAt: 0)),
    );
  });

  test('缺 manifest / 缺载荷 / 载荷形状错', () {
    _expectCode('nonapp_missing_manifest', _zip({'payload/index.html': _html()}));
    _expectCode('nonapp_missing_payload', _pkg({}));
    _expectCode(
      'nonapp_missing_payload',
      _pkg({}, manifest: _manifest(renderer: 'a2ui')),
    );
    _expectCode(
      'nonapp_invalid_surface',
      _pkg({'payload/surface.json': jsonEncode({'nope': 1})},
          manifest: _manifest(renderer: 'a2ui')),
    );
    _expectCode(
      'nonapp_invalid_surface',
      _pkg({
        'payload/surface.json': jsonEncode([1, 2]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
    _expectCode(
      'nonapp_invalid_data',
      _pkg({
        'payload/surface.json': jsonEncode(_messages),
        'payload/data.json': jsonEncode([1, 2]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
  });

  test('a2ui 浅层结构门：非内置组件 / 不支持的 action 形状一律拒', () {
    // 自定义 CatalogItem 不能随包分发（§1.1）；渲染期会抛 A2uiValidationError。
    _expectCode(
      'nonapp_invalid_surface',
      _pkg({
        'payload/surface.json': jsonEncode([
          {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 'demo',
              'components': [
                {'id': 'root', 'component': 'CustomChart'},
              ],
            },
          },
        ]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
    _expectCode(
      'nonapp_invalid_surface',
      _pkg({
        'payload/surface.json': jsonEncode([
          {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 'demo',
              'components': [
                {
                  'id': 'btn',
                  'component': 'Button',
                  'child': 'l',
                  'action': {
                    'event': {'context': <String, Object?>{}},
                  },
                },
                {'id': 'l', 'component': 'Text', 'text': 'x'},
              ],
            },
          },
        ]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
    // 合法 action（event.name 是字符串）照常放行
    final ok = NonAppPackage.parse(_pkg({
      'payload/surface.json': jsonEncode(_messages),
    }, manifest: _manifest(renderer: 'a2ui')));
    expect(ok.messages, hasLength(2));

    // 非 basic v1.0 目录：处理器只注册了一个 catalog，别的会在渲染期抛
    // A2uiCatalogError（炸页）——门口拒掉。
    _expectCode(
      'nonapp_invalid_surface',
      _pkg({
        'payload/surface.json': jsonEncode([
          {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 'demo',
              'catalogId': 'https://example.com/custom/catalog.json',
              'components': [
                {'id': 'root', 'component': 'Text', 'text': 'x'},
              ],
            },
          },
        ]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
  });

  test('客户端 parse 走服务端等价 HTML 门：<a href>/<iframe src> 不误拒', () {
    // 服务端 _html_ok 的正则只覆盖 script/link/img；客户端若在 parse 里用
    // 更严的离线门，服务端接受的包（导出→打开自家应用）会解不开。
    for (final tag in const [
      '<a href="https://example.com/docs">文档</a>',
      '<iframe src="https://example.com/embed"></iframe>',
      '<img src="data:image/png;base64,AAAA">',
    ]) {
      final pkg = NonAppPackage.parse(_pkg({
        'payload/index.html': _html().replaceFirst('<canvas id=c>', '<canvas id=c>$tag'),
      }));
      expect(pkg.renderer, 'html', reason: tag);
    }
    // script/link/img 的外链仍然拒（与服务端同判据）
    _expectCode(
      'nonapp_html_external_refs',
      _pkg({'payload/index.html': _html().replaceFirst('<canvas id=c>',
          '<canvas id=c></canvas><img src="https://evil.example/x.png">')}),
    );
    // 离线门（更严）单独可调：同样一份 HTML 在 file:// 前必须拒
    expect(
      () => assertHtmlOfflineSafe(_html().replaceFirst('<canvas id=c>',
          '<canvas id=c></canvas><a href="https://example.com/docs">文档</a>')),
      throwsA(isA<NonAppException>().having((e) => e.code, 'code', 'nonapp_html_external_refs')),
    );
  });

  test('a2ui 零外链门：组件 url 与 dataModel 里的地址都拒', () {
    // Image/Video/AudioPlayer 会直接网络拉取（a2ui_flutter 0.3.0
    // image.dart:47 / media.dart:131），dataModel 里的 URL 也会经绑定喂进去。
    _expectCode(
      'nonapp_a2ui_external_refs',
      _pkg({
        'payload/surface.json': jsonEncode([
          {
            'version': '1.0',
            'createSurface': {
              'surfaceId': 'demo',
              'catalogId': nonAppBasicCatalogId,
              'components': [
                {'id': 'root', 'component': 'Image', 'url': 'https://evil.example/x.png'},
              ],
            },
          },
        ]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
    _expectCode(
      'nonapp_a2ui_external_refs',
      _pkg({
        'payload/surface.json': jsonEncode([
          {
            'version': '1.0',
            'createSurface': {'surfaceId': 'demo', 'catalogId': nonAppBasicCatalogId, 'components': []},
          },
          {
            'version': '1.0',
            'dataModelUpdate': {
              'surfaceId': 'demo',
              'path': '/',
              'contents': [
                {'key': 'img', 'valueString': '//cdn.example/a.png'},
              ],
            },
          },
        ]),
      }, manifest: _manifest(renderer: 'a2ui')),
    );
    // catalogId 本身是 https URL，属结构字段——不得误伤
    final ok = NonAppPackage.parse(_pkg({
      'payload/surface.json': jsonEncode(_messages),
    }, manifest: _manifest(renderer: 'a2ui')));
    expect(ok.messages, hasLength(2));
  });

  test('html 零外链保守预筛：http(s)、协议相对、绝对路径、短文档', () {
    _expectCode(
      'nonapp_html_external_refs',
      _pkg({'payload/index.html': _html().replaceFirst('<canvas id=c>',
          '<img src="https://evil.example/x.png">')}),
    );
    _expectCode(
      'nonapp_html_external_refs',
      _pkg({'payload/index.html': _html().replaceFirst('<canvas id=c>',
          '<img src="//cdn.example/x.png">')}),
    );
    _expectCode(
      'nonapp_html_external_refs',
      _pkg({'payload/index.html': _html().replaceFirst('</style>',
          '.x{background:url(/abs/bg.png)}</style>')}),
    );
    _expectCode(
      'nonapp_html_invalid',
      _pkg({'payload/index.html': '<html>short</html>'}),
    );
  });

  test('内联 SVG 的 xmlns 声明不算外链（服务端同样放行）', () {
    final svg = _html().replaceFirst(
      '<canvas id=c>',
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>',
    );
    final pkg = NonAppPackage.parse(_pkg({'payload/index.html': svg}));
    expect(pkg.renderer, 'html');
  });

  test('体积上限与坏 zip', () {
    _expectCode('nonapp_too_large', List<int>.filled(nonAppMaxPackageBytes + 1, 0));
    _expectCode('nonapp_invalid_zip', utf8.encode('not a zip at all'));
    _expectCode('nonapp_empty_body', const <int>[]);
    _expectCode(
      'nonapp_too_large',
      _pkg({'payload/index.html': List<int>.filled(nonAppMaxEntryBytes + 1, 0x20)}),
    );
  });

  test('语义化版本比较与 minAppVersion 门', () {
    expect(compareVersions('0.1.0', '0.1.0'), 0);
    expect(compareVersions('0.1.0', '0.2.0'), lessThan(0));
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));

    _expectCode(
      'nonapp_requires_app:9.9.9',
      _pkg({'payload/index.html': _html()}, manifest: _manifest(minAppVersion: '9.9.9')),
    );
    // 低版本要求照常放行
    final pkg = NonAppPackage.parse(
      _pkg({'payload/index.html': _html()}, manifest: _manifest(minAppVersion: '0.0.1')),
    );
    expect(pkg.manifest.minAppVersion, '0.0.1');
  });
}
