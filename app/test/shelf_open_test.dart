// 艺术架「一键打开」四类产物回归（2026-11-17 S2）：
// - hotapp   → hotAppLoadOnOpen（应用名，不是路径）+ plugin:hotapp
// - video    → videoLoadOnOpen（mp4 绝对路径）+ plugin:video（真播放面）
// - three    → threeLoadOnOpen（项目名）+ plugin:three
// - prototype→ store.openProjectPath（needPassword 弹一次口令框重试，
//              opened 后落 design 视图）
// 旧实现的 video 分支只弹 SnackBar，用户拿到的只是路径字符串。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
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

const _videoPath = '/Users/x/Documents/NoNDesign/videos/job-1/frames.mp4';

const _items = [
  {
    'kind': 'hotapp',
    'ref': 'app-a',
    'title': '热应用甲',
    'path': '/tmp/hotapps/app-a/index.html',
    'detail': '热应用',
  },
  {
    'kind': 'video',
    'ref': _videoPath,
    'title': '视频乙',
    'path': _videoPath,
    'detail': '视频渲染产物',
  },
  {
    'kind': 'three',
    'ref': 'scene-c',
    'title': '3D 丙',
    'path': '/tmp/3d/scene-c/scene.js',
    'detail': 'three.js 场景',
  },
];

/// /portfolio + /project/open + /engine/render 假服务器。password 非空时
/// 首次 open 返回 need_password（验证口令框一次重试）。
NoNDesignApi _api({String password = ''}) => NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/health':
          return _json({'ok': true});
        case '/project/list':
          return _json({'ok': true, 'projects': []});
        case '/portfolio':
          return _json({'ok': true, 'items': _items});
        case '/project/open':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (password.isNotEmpty && body['password'] != password) {
            return _json({'need_password': true});
          }
          return _json({'ok': true, 'path': body['path'], 'mbt': 'MBT_1', 'docs': {}});
        case '/engine/render':
          return _json({
            'ok': true,
            'mbt': 'MBT_1',
            'entry': 'home',
            'revision': 1,
            'artboards': [
              {'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': []},
            ],
            'flows': [],
          });
      }
      return _json({'ok': false, 'detail': 'no_route'}, 404);
    }));

AppStore _store(NoNDesignApi api) {
  final store = AppStore();
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.api = api;
  // 打开项目会清 recovery.json：测试绝不碰真实 ~/.nondesign。
  store.recoveryDir = Directory.systemTemp.createTempSync('dd-shelf-open').path;
  return store;
}

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
    value: store,
    child: MaterialApp(
      theme: AppTheme.build(dark: true),
      home: const Scaffold(body: PortfolioView()),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 150));
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _resetGlobals();
  });
  tearDown(_resetGlobals);

  testWidgets('热应用卡：打开 = 应用名通道 + 热应用工作台', (tester) async {
    final store = _store(_api());
    await _pump(tester, store);

    await _openCard(tester, '热应用甲');

    expect(hotAppLoadOnOpen, 'app-a');
    expect(store.view, 'plugin:hotapp');
  });

  testWidgets('视频卡：打开 = mp4 路径通道 + 视频工作台（不再是 SnackBar）', (tester) async {
    final store = _store(_api());
    await _pump(tester, store);

    await _openCard(tester, '视频乙');

    expect(videoLoadOnOpen, _videoPath);
    expect(store.view, 'plugin:video');
    // 旧实现只弹一条 SnackBar（'视频产物：<path>'）：新实现切视图，不弹。
    expect(find.textContaining('视频产物：'), findsNothing);
  });

  testWidgets('3D 卡：打开 = 项目名通道 + 3D 工作台', (tester) async {
    final store = _store(_api());
    await _pump(tester, store);

    await _openCard(tester, '3D 丙');

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
