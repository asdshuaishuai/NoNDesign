// 热应用本地面（app/lib/core/hotapp_service.dart / hotapp_db.dart /
// nonapp_library.dart）回归。
//
// 覆盖：
//  · 生成：模型回包 → 离线门 → 本地库落盘（manifest / 页面 / 每应用数据库）；
//  · fail-closed：外链页面、重名、模型异常都不留半成品、不覆盖旧版本；
//  · 精修：成功覆盖页面、保留数据库；失败保留旧页面；
//  · 数据面：SQL 门（ATTACH / 多语句 / 可写 schema 拒绝）、BLOB 编码、
//    查询/写入回包形状；
//  · 预览运行时注入：CSP 在前、数据桥在后、两者都早于页面内容。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/hotapp_db.dart';
import 'package:nondesign/core/hotapp_service.dart';
import 'package:nondesign/core/nonapp_library.dart';

String _validHtml({String marker = 'hotapp-marker'}) =>
    '<!doctype html><html><head><meta charset="utf-8"><style>'
    'html,body{margin:0;height:100%;background:linear-gradient(120deg,#1b1b2f,#3a2f5b)}'
    'canvas{display:block;width:100%;height:70vh}'
    '.t{color:#eee;font:14px system-ui;text-align:center;padding:8px}'
    '</style></head><body><div class="t">$marker</div><canvas id="c"></canvas>'
    '<script>var c=document.getElementById("c");var x=c.getContext("2d");'
    'function f(){x.clearRect(0,0,c.width,c.height);requestAnimationFrame(f);}f();'
    '</script></body></html>';

HotAppLlmConfig _config() => const HotAppLlmConfig(
      model: 'test-model',
      baseUrl: 'https://model.invalid/v1',
      apiKey: 'test-key',
    );

void main() {
  late Directory root;
  late NonAppLibrary library;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('hotapp_local_');
    library = await NonAppLibrary.open(root: Directory('${root.path}/hotapps'));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('生成', () {
    test('模型回包（带围栏）→ 本地库：manifest / 页面 / 每个应用一个数据库', () async {
      final service = HotAppService(
        library: library,
        llm: (request) async {
          expect(request.prompt, contains('弹跳小球'));
          expect(request.system, contains('window.NoN.db.exec'));
          return '好的，这是页面：\n```html\n${_validHtml()}\n```\n';
        },
      );

      final entry = await service.generate(
        name: 'bounce-demo',
        brief: '弹跳小球',
        config: _config(),
      );

      expect(entry.name, 'bounce-demo');
      expect(entry.renderer, 'html');
      expect(entry.title, '弹跳小球');
      final page = File('${entry.dir}/index.html');
      expect(page.existsSync(), isTrue);
      expect(page.readAsStringSync(), contains('hotapp-marker'));
      expect(page.readAsStringSync().startsWith('<!doctype html>'), isTrue,
          reason: '围栏与说明文字必须被剥掉');
      expect(File('${entry.dir}/app.db').existsSync(), isTrue);

      final manifest = jsonDecode(File('${entry.dir}/manifest.json').readAsStringSync()) as Map;
      expect(manifest['name'], 'bounce-demo');
      expect(manifest['id'], 'bounce-demo');
      expect(manifest['renderer'], 'html');
      expect(manifest['minAppVersion'], isNotEmpty);

      final apps = await service.list();
      expect(apps.map((a) => a.name), ['bounce-demo']);
    });

    test('外链页面：拒绝且不留半成品（fail-closed）', () async {
      final service = HotAppService(
        library: library,
        llm: (_) async => _validHtml().replaceFirst(
          '<canvas id="c"></canvas>',
          '<canvas id="c"></canvas><img src="https://evil.example/x.png">',
        ),
      );

      await expectLater(
        service.generate(name: 'bad-app', brief: '外链', config: _config()),
        throwsA(isA<HotAppFailure>()
            .having((e) => e.code, 'code', 'html_external_refs')),
      );
      expect(await service.list(), isEmpty, reason: '被拒的生成不得留下目录');
      expect(Directory('${library.root.path}/.install-bad-app').existsSync(), isFalse);
    });

    test('重名：拒绝覆盖旧应用，旧页面原样保留', () async {
      final service = HotAppService(
        library: library,
        llm: (_) async => _validHtml(marker: 'first'),
      );
      await service.generate(name: 'same-name', brief: '第一版', config: _config());

      final again = HotAppService(
        library: library,
        llm: (_) async => _validHtml(marker: 'second'),
      );
      await expectLater(
        again.generate(name: 'same-name', brief: '第二版', config: _config()),
        throwsA(isA<HotAppFailure>().having((e) => e.code, 'code', 'name_taken')),
      );
      expect((await again.html('same-name'))!, contains('first'));
    });

    test('模型未配置 / 空需求 / 非法名字：调用前失败，不碰磁盘', () async {
      var called = 0;
      final service = HotAppService(library: library, llm: (_) async {
        called++;
        return _validHtml();
      });

      await expectLater(
        service.generate(name: 'ok-name', brief: 'x', config: const HotAppLlmConfig(model: 'm', baseUrl: '', apiKey: '')),
        throwsA(isA<HotAppFailure>()),
      );
      await expectLater(
        service.generate(name: 'ok-name', brief: '   ', config: _config()),
        throwsA(isA<HotAppFailure>().having((e) => e.code, 'code', 'brief_empty')),
      );
      await expectLater(
        service.generate(name: 'Bad Name', brief: 'x', config: _config()),
        throwsA(isA<HotAppFailure>().having((e) => e.code, 'code', 'name_invalid')),
      );
      expect(called, 0);
      expect(await service.list(), isEmpty);
    });
  });

  group('精修', () {
    test('成功：页面覆盖、数据库保留、manifest 标题不变', () async {
      final first = HotAppService(
        library: library,
        llm: (_) async => _validHtml(marker: 'v1'),
      );
      final created = await first.generate(name: 'refine-me', brief: '初版', config: _config());

      final db = first.openDb('refine-me');
      db.exec('CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)');
      db.exec("INSERT INTO notes (body) VALUES ('keep-me')");
      db.dispose();

      final second = HotAppService(
        library: library,
        llm: (request) async {
          expect(request.prompt, contains('v1'));
          expect(request.prompt, contains('换成绿色'));
          return _validHtml(marker: 'v2');
        },
      );
      final refined = await second.refine(
        name: 'refine-me',
        instruction: '换成绿色',
        config: _config(),
      );

      expect(refined.title, created.title);
      expect(refined.createdAt, created.createdAt);
      expect((await second.html('refine-me'))!, contains('v2'));

      final reopened = second.openDb('refine-me');
      final rows = reopened.exec('SELECT body FROM notes');
      reopened.dispose();
      expect((rows['rows'] as List).single['body'], 'keep-me',
          reason: '精修不得清空应用数据');
    });

    test('失败：旧页面原样保留（覆盖是最后一步）', () async {
      final first = HotAppService(
        library: library,
        llm: (_) async => _validHtml(marker: 'stable'),
      );
      await first.generate(name: 'stable-app', brief: '稳定', config: _config());

      final broken = HotAppService(
        library: library,
        llm: (_) async => _validHtml(marker: 'broken')
            .replaceFirst('<canvas id="c"></canvas>',
                '<canvas id="c"></canvas><script src="https://evil.example/a.js"></script>'),
      );
      await expectLater(
        broken.refine(name: 'stable-app', instruction: '加个广告', config: _config()),
        throwsA(isA<HotAppFailure>()),
      );
      expect((await broken.html('stable-app'))!, contains('stable'));
    });
  });

  group('数据面', () {
    test('SQL 门：只放行单条白名单语句，文件系统能力一律拒绝', () {
      expect(hotAppSqlRejectReason('SELECT 1'), isNull);
      expect(hotAppSqlRejectReason('select * from t;'), isNull);
      expect(hotAppSqlRejectReason('CREATE TABLE t (x TEXT)'), isNull);
      expect(hotAppSqlRejectReason('WITH x AS (SELECT 1) SELECT * FROM x'), isNull);
      expect(hotAppSqlRejectReason('PRAGMA user_version'), isNull);

      expect(hotAppSqlRejectReason('SELECT 1; DROP TABLE t'), 'multiple_statements');
      expect(hotAppSqlRejectReason("ATTACH DATABASE '/tmp/x' AS y"), isNotNull);
      expect(hotAppSqlRejectReason('/*x*/ attach database \'/tmp/x\' as y'), isNotNull);
      expect(hotAppSqlRejectReason('PRAGMA writable_schema = ON'),
          'keyword_not_allowed:writable_schema');
      expect(hotAppSqlRejectReason('PRAGMA hard_heap_limit = 0'),
          'keyword_not_allowed:hard_heap_limit');
      expect(hotAppSqlRejectReason("SELECT load_extension('x')"),
          'keyword_not_allowed:load_extension');
      expect(hotAppSqlRejectReason("VACUUM INTO '/tmp/out.db'"), isNotNull);
      expect(hotAppSqlRejectReason('   '), 'empty');
      // 无界递归 CTE 与超大 blob 生成：一次调用就能冻结/拖垮宿主。
      expect(
        hotAppSqlRejectReason(
          'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT x FROM c',
        ),
        'recursive_cte_not_allowed',
      );
      expect(hotAppSqlRejectReason('SELECT randomblob(2000000000)'), 'blob_too_large');
      expect(hotAppSqlRejectReason('SELECT zeroblob(1000000000)'), 'blob_too_large');
      expect(hotAppSqlRejectReason('SELECT randomblob(1024)'), isNull);
    });

    test('写入/查询回包形状：changes、last_insert_rowid、BLOB base64、行截断标记', () {
      final dir = Directory('${root.path}/db-app');
      final db = HotAppDb.openForApp(dir.path);
      addTearDown(db.dispose);

      final create = db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT, blob BLOB)');
      expect(create['ok'], isTrue);

      final insert = db.exec(
        'INSERT INTO t (body, blob) VALUES (?, ?)',
        ['hello', Uint8List.fromList([1, 2, 3])],
      );
      expect(insert['ok'], isTrue);
      expect(insert['changes'], 1);
      expect(insert['last_insert_rowid'], 1);

      final rows = db.exec('SELECT body, blob FROM t');
      final row = (rows['rows'] as List).single as Map;
      expect(row['body'], 'hello');
      expect((row['blob'] as Map)['base64'], base64Encode([1, 2, 3]));

      expect(
        () => db.exec('SELECT 1; DROP TABLE t'),
        throwsA(isA<HotAppDbFailure>().having((e) => e.code, 'code', 'db_sql_rejected')),
      );
    });

    test('大结果有界：行数上限触发截断标记', () {
      final db = HotAppDb.openForApp('${root.path}/big-app');
      addTearDown(db.dispose);
      db.exec('CREATE TABLE n (v INTEGER)');
      for (var i = 0; i < 620; i++) {
        db.exec('INSERT INTO n (v) VALUES (?)', [i]);
      }
      final result = db.exec('SELECT v FROM n');
      expect((result['rows'] as List).length, hotAppDbMaxRows);
      expect(result['truncated'], isTrue);
    });
  });

  group('预览运行时注入', () {
    test('CSP 在前、数据桥在后，且都早于页面内容', () {
      final injected = injectHotAppRuntime(_validHtml());
      final csp = injected.indexOf('http-equiv="Content-Security-Policy"');
      final bridge = injected.indexOf('window.NoN.db');
      final marker = injected.indexOf('hotapp-marker');
      expect(csp, greaterThanOrEqualTo(0));
      expect(bridge, greaterThan(csp));
      expect(marker, greaterThan(bridge), reason: '策略与桥必须先于页面内容生效');
      expect(injected, contains(hotAppDbChannel));
      expect(injected, contains(hotAppDbResultFunction));
      expect(injected, contains("addEventListener('error'"));
      expect(injected, contains('unhandledrejection'));
      expect(injected, contains("connect-src 'self'"));
    });
  });

  group('由原型生成（可验证）', () {
    PrototypeScreenSpec screen(String id) => PrototypeScreenSpec(id: id, title: id);

    String protoHtml({required bool withSettings, required bool withNav}) {
      final settingsSection = withSettings
          ? '<section data-screen="settings"><h1>设置</h1></section>'
          : '';
      final nav = withNav ? '<button data-nav="settings">去设置</button>' : '';
      return '<!doctype html><html><head><meta charset="utf-8"><style>'
              'body{margin:0;font:14px system-ui;background:#fff;color:#111}'
              '</style></head><body>'
              '<section data-screen="home"><h1>番茄钟</h1><div>25:00</div>$nav</section>'
              '$settingsSection'
              '<script>document.addEventListener("click",function(e){'
              'var t=e.target.closest("[data-nav]");if(!t)return;'
              'var to=t.getAttribute("data-nav");'
              'document.querySelectorAll("[data-screen]").forEach(function(s){'
              's.style.display=s.getAttribute("data-screen")===to?"block":"none";});});'
              '</script></body></html>';
    }

    test('全量覆盖：屏幕 + 连线都实现 → verified=true', () async {
      late String capturedPrompt;
      final service = HotAppService(
        library: library,
        llm: (request) async {
          capturedPrompt = request.prompt;
          return protoHtml(withSettings: true, withNav: true);
        },
      );

      final result = await service.generateFromPrototype(
        name: 'proto-pomodoro',
        config: _config(),
        prototypeMbt: '---\nmoonviz:\n  entry: home\n---\n# home …\n# settings …',
        screens: [screen('home'), screen('settings')],
        flows: [PrototypeLinkSpec(from: 'home', to: 'settings')],
      );

      expect(result.verified, isTrue, reason: result.failureSummary);
      expect(result.app.name, 'proto-pomodoro');
      expect(result.checks.map((c) => c.ok), everyElement(isTrue));
      // 提示词必须带上画板清单、跳转清单与确定性标记要求
      expect(capturedPrompt, contains('data-screen="home"'));
      expect(capturedPrompt, contains('data-screen="settings"'));
      expect(capturedPrompt, contains('data-nav="settings"'));
      expect(capturedPrompt, contains('home → settings'));
      final page = File('${result.app.dir}/index.html');
      expect(page.existsSync(), isTrue);
    });

    test('缺画板：应用仍入库，但如实标注未通过项', () async {
      final service = HotAppService(
        library: library,
        llm: (_) async => protoHtml(withSettings: false, withNav: true),
      );

      final result = await service.generateFromPrototype(
        name: 'proto-missing',
        config: _config(),
        prototypeMbt: '原型文档',
        screens: [screen('home'), screen('settings')],
        flows: const [],
      );

      expect(result.verified, isFalse);
      expect(result.failureSummary, contains('缺少画板 settings'));
      final apps = await service.list();
      expect(apps.map((a) => a.name), contains('proto-missing'),
          reason: '结构门已过的产物不回滚，缺覆盖要如实上报');
    });

    test('缺连线：from 段落里没有 data-nav → 该跳转检查失败', () async {
      final service = HotAppService(
        library: library,
        llm: (_) async => protoHtml(withSettings: true, withNav: false),
      );

      final result = await service.generateFromPrototype(
        name: 'proto-no-link',
        config: _config(),
        prototypeMbt: '原型文档',
        screens: [screen('home'), screen('settings')],
        flows: [PrototypeLinkSpec(from: 'home', to: 'settings')],
      );

      expect(result.verified, isFalse);
      expect(result.failureSummary, contains('缺少连线'));
      final okFlow = result.checks.where((c) => c.id == 'screen_home');
      expect(okFlow.single.ok, isTrue, reason: '画板在，缺的是连线');
    });
  });
}
