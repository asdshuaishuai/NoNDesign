// 本地应用库（app/lib/core/nonapp_library.dart）回归。
//
// 覆盖：
//  · 安装：html / a2ui 两种载荷 → 目录 + manifest + 每个应用一个数据库；
//  · 导入即新实例：同名再导入清空旧数据；
//  · 导出：buildPackage 产出的字节能被 NonAppPackage.parse 重新解析（语义互操作）；
//  · 删除与扫描：损坏目录显式呈现、临时目录不参与扫描；
//  · 离线门：服务端等价面放行的包（<a href=https>）在落盘前被更严的门拒绝。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/hotapp_db.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';

String _html({String marker = 'library-marker'}) =>
    '<!doctype html><html><head><meta charset="utf-8"><style>'
    'body{background:#111;color:#eee;font:14px system-ui;padding:12px}'
    '</style></head><body><div id="m">$marker</div>'
    '<script>document.getElementById("m").dataset.ready="1";</script></body></html>';

final List<Object?> _surface = [
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
];

List<int> _zip(Map<String, Object?> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    final bytes = e.value is String ? utf8.encode(e.value as String) : e.value as List<int>;
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

Map<String, Object?> _manifest({
  String name = 'demo-app',
  String title = '演示应用',
  String renderer = 'html',
  int createdAt = 1700000000,
  String? brief,
}) =>
    {
      'formatVersion': 1,
      'id': name,
      'name': name,
      'title': title,
      'renderer': renderer,
      'createdAt': createdAt,
      'minAppVersion': '0.1.0',
      'brief': ?brief,
    };

List<int> _htmlPackage({String name = 'demo-app', String marker = 'library-marker'}) => _zip({
      'manifest.json': jsonEncode(_manifest(name: name)),
      'payload/index.html': _html(marker: marker),
    });

List<int> _a2uiPackage({String name = 'a2ui-app', bool withExtras = false}) => _zip({
      'manifest.json': jsonEncode(_manifest(name: name, renderer: 'a2ui', title: '交互应用')),
      'payload/surface.json': jsonEncode(_surface),
      if (withExtras) 'payload/data.json': jsonEncode({'items': <Object>[]}),
      if (withExtras) 'payload/prompt.txt': '继续完善',
    });

void main() {
  late Directory root;
  late NonAppLibrary library;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nonapp_library_');
    library = await NonAppLibrary.open(root: Directory('${root.path}/hotapps'));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('安装 html 包：目录 / 清单 / 页面 / 每应用数据库', () async {
    final entry = await installNonAppBytes(library, Uint8List.fromList(_htmlPackage()));

    expect(entry.name, 'demo-app');
    expect(entry.title, '演示应用');
    expect(entry.renderer, 'html');
    expect(entry.corrupt, isFalse);
    expect(File('${entry.dir}/manifest.json').existsSync(), isTrue);
    expect(File('${entry.dir}/index.html').readAsStringSync(), contains('library-marker'));
    expect(File('${entry.dir}/app.db').existsSync(), isTrue);
    expect(entry.payloadBytes, greaterThan(0));
  });

  test('导入 = 新实例：同名再导入清空旧数据', () async {
    final first = await installNonAppBytes(library, Uint8List.fromList(_htmlPackage()));
    final db = library.openDb(first.name);
    db.exec('CREATE TABLE notes (body TEXT)');
    db.exec("INSERT INTO notes (body) VALUES ('old')");
    db.dispose();

    final second = await installNonAppBytes(library, Uint8List.fromList(_htmlPackage()));
    expect(second.name, first.name);

    final reopened = library.openDb(second.name);
    final tables = reopened.exec("SELECT name FROM sqlite_master WHERE type='table'");
    reopened.dispose();
    final names = [for (final row in tables['rows'] as List) row['name']];
    expect(names, isNot(contains('notes')), reason: '导入是新实例，旧数据不继承');
  });

  test('安装 a2ui 包：surface/data/prompt 一并保留，页面不写 html', () async {
    final entry = await installNonAppBytes(
      library,
      Uint8List.fromList(_a2uiPackage(withExtras: true)),
    );
    expect(entry.isA2ui, isTrue);
    expect(File('${entry.dir}/surface.json').existsSync(), isTrue);
    expect(File('${entry.dir}/index.html').existsSync(), isFalse);
    expect(File('${entry.dir}/data.json').existsSync(), isTrue);
    expect(File('${entry.dir}/prompt.txt').readAsStringSync(), '继续完善');

    final messages = await library.readSurface(entry.name);
    expect(messages, isNotNull);
    expect((messages!.first as Map)['createSurface'], isNotNull);
    expect(await library.readHtml(entry.name), isNull);
  });

  test('导出：buildPackage 产出的字节可被重新解析（语义互操作）', () async {
    final entry = await installNonAppBytes(
      library,
      Uint8List.fromList(_htmlPackage(marker: 'round-trip')),
    );
    final bytes = await library.buildPackage(entry.name);
    final parsed = NonAppPackage.parse(bytes);
    expect(parsed.manifest.name, entry.name);
    expect(parsed.manifest.renderer, 'html');
    expect(utf8.decode(parsed.htmlBytes!), contains('round-trip'));

    final a2 = await installNonAppBytes(
      library,
      Uint8List.fromList(_a2uiPackage(name: 'a2-round', withExtras: true)),
    );
    final a2Bytes = await library.buildPackage(a2.name);
    final a2Parsed = NonAppPackage.parse(a2Bytes);
    expect(a2Parsed.manifest.renderer, 'a2ui');
    expect(a2Parsed.messages, isNotNull);
    expect(a2Parsed.data?['items'], isNotNull);
    expect(a2Parsed.prompt, '继续完善');
  });

  test('扫描：按创建时间倒序；损坏目录显式呈现；隐藏临时目录跳过', () async {
    await installNonAppBytes(
      library,
      Uint8List.fromList(_htmlPackage(name: 'old-app')),
    );
    // 直接改清单时间模拟更晚创建的应用。
    final newer = '${library.root.path}/new-app';
    Directory(newer).createSync(recursive: true);
    File('$newer/manifest.json').writeAsStringSync(jsonEncode({
      ..._manifest(name: 'new-app', createdAt: 1800000000, title: '新应用'),
    }));
    File('$newer/index.html').writeAsStringSync(_html());

    // 损坏：有清单没载荷；无清单：整个目录跳过。
    final broken = '${library.root.path}/broken-app';
    Directory(broken).createSync(recursive: true);
    File('$broken/manifest.json').writeAsStringSync(jsonEncode(_manifest(name: 'broken-app')));
    Directory('${library.root.path}/no-manifest').createSync(recursive: true);
    Directory('${library.root.path}/.install-temp').createSync(recursive: true);

    final apps = await library.scan();
    // 时间相同按名字排序（new-app 最新；old-app / broken-app 同为旧时间）。
    expect(apps.map((a) => a.name).toList(), ['new-app', 'broken-app', 'old-app']);
    expect(apps.firstWhere((a) => a.name == 'broken-app').corrupt, isTrue);
    expect(apps.any((a) => a.name == 'no-manifest'), isFalse);
    expect(apps.any((a) => a.name.startsWith('.')), isFalse);
  });

  test('删除：目录与应用数据一起移除；再删幂等', () async {
    final entry = await installNonAppBytes(library, Uint8List.fromList(_htmlPackage()));
    await library.delete(entry.name);
    expect(Directory(entry.dir).existsSync(), isFalse);
    await library.delete(entry.name); // 幂等
    expect(await library.scan(), isEmpty);
  });

  test('离线门更严：服务端等价面放行的 <a href=https> 在落盘前被拒', () async {
    final linked = _html().replaceFirst(
      '<div id="m">library-marker</div>',
      '<div id="m">library-marker</div><a href="https://example.com/docs">文档</a>',
    );
    // 解析层（服务端等价面）放行：在线路径的历史兼容行为不变。
    final parsed = NonAppPackage.parse(_zip({
      'manifest.json': jsonEncode(_manifest(name: 'linked-app')),
      'payload/index.html': linked,
    }));
    expect(parsed.renderer, 'html');

    await expectLater(
      library.install(parsed),
      throwsA(isA<NonAppException>()
          .having((e) => e.code, 'code', startsWith('nonapp_html_external_refs'))),
    );
    expect(Directory('${library.root.path}/linked-app').existsSync(), isFalse);
    expect(await library.scan(), isEmpty, reason: '被拒的包不留任何目录');
  });

  test('拒绝非法应用名（路径穿越面）', () {
    for (final name in ['../evil', 'a/b', '', 'x' * 65, 'bad name']) {
      expect(
        () => library.appDir(name),
        throwsA(isA<NonAppException>()),
        reason: 'appDir($name) 必须拒绝',
      );
    }
  });

  test('数据库句柄按应用隔离：两个应用互不可见', () async {
    final a = await installNonAppBytes(library, Uint8List.fromList(_htmlPackage(name: 'app-a')));
    final b = await installNonAppBytes(library, Uint8List.fromList(_htmlPackage(name: 'app-b')));
    final dba = library.openDb(a.name);
    dba.exec('CREATE TABLE only_a (v TEXT)');
    dba.dispose();

    final dbb = library.openDb(b.name);
    final tables = dbb.exec("SELECT name FROM sqlite_master WHERE type='table'");
    dbb.dispose();
    expect([for (final row in tables['rows'] as List) row['name']], isNot(contains('only_a')));
    expect(HotAppDb.openForApp(a.dir).path, isNot(HotAppDb.openForApp(b.dir).path));
  });
}
