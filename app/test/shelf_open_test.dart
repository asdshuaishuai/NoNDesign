// 艺术架「一键打开」四类产物回归（批次 07：全本地数据面）。
// - hotapp   → hotAppLoadOnOpen（应用名，不是路径）+ plugin:hotapp
// - video    → videoLoadOnOpen（mp4 绝对路径）+ plugin:video（真播放面）
// - three    → threeLoadOnOpen（项目名）+ plugin:three
// - prototype→ store.openProjectPath（needPassword 弹一次口令框重试，
//              opened 后落 design 视图）
// 旧实现的 video 分支只弹 SnackBar，用户拿到的只是路径字符串。
//
// 数据来源：热应用/3D/视频都来自本机目录扫描（`NonAppLibrary` /
// `ThreeService` / videos 目录），不再有 /portfolio 聚合端点——夹具因此
// 落在临时目录里，用 `PortfolioView` 的注入参数接线（shelf_layout_test 同法）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/art_shelf_card.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

String _html({String marker = 'shelf-marker'}) =>
    '<!doctype html><html><head><meta charset="utf-8"><style>'
    'body{background:#111;color:#eee;font:14px system-ui;padding:12px}'
    '</style></head><body><div>$marker</div>'
    '<script>document.body.dataset.ready="1";</script></body></html>';

List<int> _package({required String name, required String title}) {
  final archive = Archive();
  void add(String entry, List<int> bytes) =>
      archive.addFile(ArchiveFile(entry, bytes.length, bytes));
  add('manifest.json', utf8.encode(jsonEncode({
    'formatVersion': 1,
    'id': name,
    'name': name,
    'title': title,
    'renderer': 'html',
    'createdAt': 1700000000,
    'minAppVersion': '0.1.0',
  })));
  add('payload/index.html', utf8.encode(_html(marker: title)));
  return ZipEncoder().encode(archive);
}

/// /v1/rpc 假桌面：project.open 支持 need_password 一次重试（验证口令框）。
/// 热应用/视频/3D 全部走本地扫描，不经过这里。
///
/// 2026-11 起的连接桌面协议是单一 RPC 端点 `/v1/rpc`（method + params，
/// 回复 `{ok, result}`），旧的 `/project/open` 分路由已随 LocalCore 迁移退役。
NoNDesignApi _api({String password = ''}) =>
    NoNDesignApi('http://mock.local', MockClient((request) async {
      if (request.url.path == '/v1/rpc') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final method = body['method'] as String?;
        final params = (body['params'] as Map?) ?? const <String, dynamic>{};
        switch (method) {
          case 'project.open':
            final path = params['path'];
            if (password.isNotEmpty && params['password'] != password) {
              return _json({
                'ok': true,
                'result': {'ok': false, 'need_password': true, 'path': path},
              });
            }
            return _json({
              'ok': true,
              'result': {'ok': true, 'path': path, 'mbt': 'MBT_1', 'docs': <String, dynamic>{}},
            });
          case 'project.list':
            return _json({
              'ok': true,
              'result': {'ok': true, 'projects': <Object>[]},
            });
          case 'engine.render':
            return _json({
              'ok': true,
              'result': {
                'ok': true,
                'mbt': 'MBT_1',
                'entry': 'home',
                'revision': 1,
                'artboards': [
                  {'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': []},
                ],
                'flows': <Object>[],
              },
            });
        }
        return _json({
          'ok': true,
          'result': {'ok': true},
        });
      }
      return _json({'ok': false, 'error': 'no_route'}, 404);
    }));

AppStore _store(NoNDesignApi api) {
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.api = api;
  // 打开项目会清 recovery.json：测试绝不碰真实 ~/.nondesign。
  store.recoveryDir = Directory.systemTemp.createTempSync('dd-shelf-open').path;
  return store;
}

Future<void> _settle(WidgetTester tester) async {
  // 本地扫描走 dart:io（目录枚举/文件 stat）：widget test 的假时钟只推进
  // 微任务，不推进真实 IO。交替 pump 与 runAsync 若干轮，让整条
  // 「项目发现 → 热应用库 → 3D → 视频」链路逐段完成。
  for (var i = 0; i < 25; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

late Directory _temp;
late Directory _threeDir;
late Directory _videoDir;
late NonAppLibrary _library;
late String _videoPath;

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
    value: store,
    child: MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(
        body: PortfolioView(
          library: _library,
          threeService: ThreeService(root: _threeDir),
          videoRoot: _videoDir,
        ),
      ),
    ),
  ));
  await _settle(tester);
}

/// 点某张卡片的「打开」（卡片本体也可点，这里走显式按钮）。
Future<void> _openCard(WidgetTester tester, String title) async {
  final card = find.ancestor(of: find.text(title), matching: find.byType(ArtShelfCard));
  expect(card, findsOneWidget, reason: '找不到卡片 $title');
  await tester.tap(find.descendant(of: card, matching: find.text('打开')));
  await tester.pump(const Duration(milliseconds: 80));
}

void _resetGlobals() {
  hotAppLoadOnOpen = null;
  videoLoadOnOpen = null;
  threeLoadOnOpen = null;
}

/// 路径比较用：Windows 上目录扫描出来的绝对路径是反斜杠，而测试夹具用
/// `/` 拼接——两种写法都指同一个文件，断言前统一归一化，别让分隔符差异
/// 变成假红（本文件在 Windows 门禁要绿）。
String _normPath(String path) => path.replaceAll('\\', '/');

/// 预置一个可续接的 3D 项目（build-state.json 是 listProjects 的识别依据）。
void _seedThreeProject(String name) {
  final dir = Directory('${_threeDir.path}/$name')..createSync(recursive: true);
  File('${dir.path}/build-state.json').writeAsStringSync(jsonEncode({
    'current': 'blockout',
    'blocked': false,
    'passes': <Object>[],
  }));
  File('${dir.path}/three-spec.json').writeAsStringSync(jsonEncode({
    'title': name,
    'summary': '',
    'components': <Object>[],
    'acceptance': <Object>[],
  }));
  File('${dir.path}/scene.js').writeAsStringSync('// scene\n');
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _resetGlobals();
    _temp = Directory.systemTemp.createTempSync('shelf_open_');
    _threeDir = Directory('${_temp.path}/3d')..createSync(recursive: true);
    _videoDir = Directory('${_temp.path}/videos/job-1')..createSync(recursive: true);
    _library = await NonAppLibrary.open(root: Directory('${_temp.path}/hotapps'));
    _videoPath = '${_videoDir.path}/frames.mp4';
  });

  tearDown(() {
    _resetGlobals();
    if (_temp.existsSync()) _temp.deleteSync(recursive: true);
  });

  testWidgets('热应用卡：打开 = 应用名通道 + 热应用工作台', (tester) async {
    await _library.install(NonAppPackage.parse(_package(name: 'app-a', title: '热应用甲')));
    final store = _store(_api());
    await _pump(tester, store);

    await _openCard(tester, '热应用甲');

    expect(hotAppLoadOnOpen, 'app-a');
    expect(store.view, 'plugin:hotapp');
  });

  testWidgets('视频卡：打开 = mp4 路径通道 + 视频工作台（不再是 SnackBar）', (tester) async {
    File(_videoPath).writeAsBytesSync([0, 0, 0, 0]);
    final store = _store(_api());
    await _pump(tester, store);

    await _openCard(tester, 'frames.mp4');

    // mp4 路径通道：目录扫描出来的绝对路径与夹具写法可能只差分隔符。
    expect(videoLoadOnOpen, isNotNull);
    expect(_normPath(videoLoadOnOpen!), _normPath(_videoPath));
    expect(store.view, 'plugin:video');
    // 旧实现只弹一条 SnackBar（'视频产物：<path>'）：新实现切视图，不弹。
    expect(find.textContaining('视频产物：'), findsNothing);
  });

  testWidgets('3D 卡：打开 = 项目名通道 + 3D 工作台', (tester) async {
    _seedThreeProject('scene-c');
    final store = _store(_api());
    await _pump(tester, store);

    await _openCard(tester, 'scene-c');

    expect(threeLoadOnOpen, 'scene-c');
    expect(store.view, 'plugin:three');
  });

  testWidgets('原型卡：needPassword 弹一次口令框，重试后打开并进设计视图', (tester) async {
    final store = _store(_api(password: 'sesame'))
      ..recent = [
        {'path': '/tmp/proto-a.ddp', 'name': 'proto-a', 'ts': 1},
      ];
    await _pump(tester, store);

    await _openCard(tester, 'proto-a');
    await tester.pumpAndSettle();

    expect(find.text('项目已加密'), findsOneWidget);
    // 艺术架头部有搜索框（M2），口令框必须按弹窗作用域定位。
    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'sesame',
    );
    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();

    expect(store.hasProject, isTrue);
    expect(store.projectName, 'proto-a');
    expect(store.view, 'design');
  });
}
