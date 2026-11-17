// 视频工作台可恢复性与反馈时序（2026-11-17 批次）：
// ① job 轮询连续失败达上限（25 × 1.2s ≈ 30s）必须放弃并复位 _busy——服务器
//    中途永久下线时 _busy 永真、「加载示例/渲染」永久禁点（工作台死端）；
// ② 环② review FAIL（ok=false / exit≠0）必须当场禁用渲染按钮并就近亮出
//    原因——此前只把 output 铺进面板，用户点了渲染才被 render.py 独立硬门
//    拒掉（反馈滞后一拍）。
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
import 'package:nondesign/widgets/video_workspace.dart';

/// json 响应（必须带 charset=utf-8：http 包的 Response 字符串体默认按
/// latin1 编码，含 ✗/中文会抛 "Contains invalid characters"——假服务器
/// 与 FastAPI 真实响应（application/json; charset=utf-8）对齐）。
http.Response _jsonRes(Object body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// /video/* 的假服务器。statusThrows：状态查询恒失败（测放弃上限）；
/// statusScript：逐次脚本（true=该次失败，false=该次成功，耗尽后恒成功，
/// 测「连续失败计数被成功响应清零」）。
class _Stub {
  bool statusThrows = false;
  final List<bool> statusScript = [];
  bool reviewFail = false;

  NoNDesignApi api() => NoNDesignApi('http://mock.local', MockClient((request) async {
        switch (request.url.path) {
          case '/video/sample':
            return _jsonRes({
              'ok': true,
              'timeline': {
                'spec': 'spec.json',
                'scenes': [
                  {'duration': 2.0, 'beats': []},
                ],
              },
              'spec': {'params': {}, 'formulas': {}},
            });
          case '/video/review':
            if (reviewFail) {
              return _jsonRes({
                'ok': false,
                'exit': 1,
                'output':
                    "[环② spec 对照] FAIL（片长 2.0s）\n  ✗ undeclared_symbol: ['undeclared_x'] 不在 spec.params ∪ spec.formulas",
              });
            }
            return _jsonRes({
              'ok': true,
              'exit': 0,
              'output': '[环② spec 对照] PASS（片长 2.0s）',
            });
          case '/video/render':
            return _jsonRes({'ok': true, 'job': 'job-1', 'dir': '/v/j1'});
          case '/video/render/status':
            if (statusThrows) throw const SocketException('connection refused');
            if (statusScript.isNotEmpty) {
              final fail = statusScript.removeAt(0);
              if (fail) throw const SocketException('connection refused');
            }
            return _jsonRes({'ok': true, 'status': 'running', 'frames': 0});
        }
        return _jsonRes('{"ok":false,"detail":"no_route"}', 404);
      }));
}

AppStore _store(NoNDesignApi api) {
  final store = AppStore()
    ..ready = true
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.api = api;
  return store;
}

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: const VideoWorkspace()),
      ),
    );

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 加载示例并等环②评审返回（两跳异步：sample → review）。
Future<void> _loadSampleAwaitingReview(WidgetTester tester) async {
  await tester.tap(find.text('加载示例'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

OutlinedButton _renderButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '渲染（后台）'));

/// 冲掉 SnackBar / 周期定时器并卸载工作台，避免测试尾部 pending timer。
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() {
    // setVideoState → saveSettings：无 mock 时 getInstance 抛 MissingPluginException。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('环② review FAIL：渲染按钮当场禁用 + 失败原因就近可见', (tester) async {
    final stub = _Stub()..reviewFail = true;
    final store = _store(stub.api());
    await _pump(tester, store);
    await _loadSampleAwaitingReview(tester);

    // 渲染门：FAIL 即禁用（此前 gate 只看 _busy/_tl，用户先撞渲染失败 toast）。
    expect(_renderButton(tester).onPressed, isNull);
    // 原因就近可见：机械对照的具体拒绝项（✗ 行）落在按钮下方的警示条里
    //（精确匹配——✗ 行全文 ≠ 面板 SelectableText 的全文）。
    expect(
        find.text("✗ undeclared_symbol: ['undeclared_x'] 不在 spec.params ∪ spec.formulas"),
        findsOneWidget);
    // 环②输出面板照常铺全文。
    expect(find.textContaining('环② spec 对照'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(store.settings.videoJob, isEmpty);
  });

  testWidgets('环② review PASS：渲染可用，点渲染建 job 并进入轮询', (tester) async {
    final stub = _Stub();
    final store = _store(stub.api());
    await _pump(tester, store);
    await _loadSampleAwaitingReview(tester);

    expect(_renderButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('渲染（后台）'));
    await tester.pump(const Duration(milliseconds: 50));
    // busy 中：两按钮都禁用。
    expect(_renderButton(tester).onPressed, isNull);
    // 轮询第一跳（1.2s 后）拿到 running：预览态显示渲染中。
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.textContaining('渲染中'), findsOneWidget);
    // 失联清场语义不受 PASS 路径影响：job 已持久化以便切视图接回。
    expect(store.settings.videoJob, 'job-1');

    await tester.pumpWidget(const SizedBox.shrink()); // dispose 取消周期定时器
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('轮询连续失败 25 次（≈30s）即放弃：复位 _busy、清 job、toast 告知', (tester) async {
    final stub = _Stub()..statusThrows = true;
    final store = _store(stub.api());
    await _pump(tester, store);
    await _loadSampleAwaitingReview(tester);

    await tester.tap(find.text('渲染（后台）'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_renderButton(tester).onPressed, isNull); // 轮询中

    // 前 24 次连续失败：仍在容忍窗口内，不得提前放弃。
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 1200));
    }
    expect(_renderButton(tester).onPressed, isNull);

    // 第 25 次：达到上限 → 取消轮询、复位 _busy、按钮恢复、toast 显式告知。
    await tester.pump(const Duration(milliseconds: 1200));
    expect(_renderButton(tester).onPressed, isNotNull);
    expect(find.textContaining('渲染任务失联'), findsOneWidget);
    expect(find.textContaining('已停止轮询'), findsOneWidget);
    // 失联任务不再持久化为在飞 job（回来不会对死任务空转轮询）。
    expect(store.settings.videoJob, isEmpty);

    await _drain(tester);
  });

  testWidgets('成功响应清零连续失败计数：断续失败永不放弃，只有连续达限才放弃', (tester) async {
    final stub = _Stub()
      ..statusScript.addAll([
        ...List<bool>.filled(24, true), // 第 1–24 次：失败（未达限）
        false, // 第 25 次：成功 → 计数清零
        ...List<bool>.filled(25, true), // 第 26–50 次：再连续失败 25 次
      ]);
    final store = _store(stub.api());
    await _pump(tester, store);
    await _loadSampleAwaitingReview(tester);

    await tester.tap(find.text('渲染（后台）'));
    await tester.pump(const Duration(milliseconds: 50));

    // 第 1–24 次失败 + 第 25 次成功（计数清零）+ 第 26–49 次失败：始终未达连续 25。
    for (var i = 0; i < 49; i++) {
      await tester.pump(const Duration(milliseconds: 1200));
    }
    expect(_renderButton(tester).onPressed, isNull); // 仍在轮询

    // 第 50 次 = 连续第 25 次失败 → 放弃。
    await tester.pump(const Duration(milliseconds: 1200));
    expect(_renderButton(tester).onPressed, isNotNull);
    expect(find.textContaining('渲染任务失联'), findsOneWidget);

    await _drain(tester);
  });
}
