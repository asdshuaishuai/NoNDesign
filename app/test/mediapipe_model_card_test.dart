// 设置里的「本地语义模型」卡（MediaPipe 388 MB 下载入口）回归：
// - 未下载时只展示状态与按钮，**打开页面绝不自动下载**；
// - 下载进度按不确定态呈现（官方只给近似大小，不画假百分比）；
// - 下载完成 → 校验通过 → 已就绪；校验失败 → 删除并提示重试；
// - 删除 → 文件消失、回到未下载；
// - 平台不支持时禁用下载并说明原因。
//
// 测试不联网、不碰真实模型目录：临时目录 + MockClient + 现场计算的 sha256。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nondesign/core/mediapipe_service.dart';
import 'package:nondesign/core/sha256_digest.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/mediapipe_model_card.dart';

const _payload = 'fake-mediapipe-card-model-bytes\n';

MediaPipeModelDescriptor _descriptor(String sha) => MediaPipeModelDescriptor(
      id: 'test_model',
      task: MediaPipeTask.retrieval,
      fileName: 'test-model.litertlm',
      url: 'https://example.test/test-model.litertlm',
      sha256: sha,
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('nondesign-mediapipe-card-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

MediaPipeService _service(Directory dir, http.Client client,
        {bool supported = true}) =>
    MediaPipeService(
      rootOverride: dir,
      httpClient: client,
      platformSupport: MediaPipePlatformSupport(
        supported: supported,
        platform: supported ? 'test/arm64' : 'test/x86',
        reason: supported ? null : 'not supported in test',
      ),
    );

/// 让真实的异步 I/O（模型探测/下载/校验）跑完，再渲染一帧。
///
/// testWidgets 默认在 fake-async 区里跑：`File.exists` 这类真实 I/O 的
/// Future 只有在 runAsync 的真实事件循环里才会完成。
Future<void> _flush(WidgetTester tester, {int ms = 60}) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
}

/// 多轮真实 I/O + 渲染：下载链路有「写临时文件 → 校验 → rename → 探测」
/// 多个 await，单轮 runAsync 只推进一段。
Future<void> _settleIo(WidgetTester tester, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) {
    await _flush(tester, ms: 12);
  }
}

void main() {
  testWidgets('未下载：展示大小与下载按钮，打开页面不自动下载', (tester) async {
    var requests = 0;
    final dir = _tempDir();
    final service = _service(dir, MockClient((req) async {
      requests++;
      return http.Response('unexpected', 500);
    }));
    final toasts = ToastService(autoDismiss: false);

    await tester.pumpWidget(_wrap(MediaPipeModelCard(
      service: service,
      model: _descriptor(sha256Hex(utf8.encode(_payload))),
      toasts: toasts,
    )));
    await _flush(tester);

    expect(find.text('本地语义模型'), findsOneWidget);
    expect(find.text('未下载'), findsOneWidget);
    expect(find.textContaining('约 388 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('mediapipe-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('mediapipe-delete')), findsNothing);
    expect(find.byKey(const ValueKey('mediapipe-progress')), findsNothing);
    expect(requests, 0, reason: '388 MB 的下载必须由用户显式触发');
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载：不确定态进度 → 校验通过 → 已就绪', (tester) async {
    final dir = _tempDir();
    final payload = utf8.encode(_payload);
    // 先扣住响应：此时还没有 Content-Length，进度只能是不确定态。
    final gate = Completer<http.StreamedResponse>();
    final service = _service(dir, MockClient.streaming((req, body) => gate.future));
    final descriptor = _descriptor(sha256Hex(payload));
    final toasts = ToastService(autoDismiss: false);

    await tester.pumpWidget(_wrap(MediaPipeModelCard(
      service: service,
      model: descriptor,
      toasts: toasts,
    )));
    await _flush(tester);

    await tester.tap(find.byKey(const ValueKey('mediapipe-download')));
    await tester.pump();

    expect(find.byKey(const ValueKey('mediapipe-progress')), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('mediapipe-progress')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(bar.value, isNull, reason: '官方只给近似大小，不显示假百分比');
    expect(find.textContaining('正在下载…'), findsOneWidget);

    gate.complete(http.StreamedResponse(
      Stream<List<int>>.fromIterable([payload.sublist(0, 6), payload.sublist(6)]),
      200,
    ));
    await tester.pump();
    await _settleIo(tester);

    expect(find.text('已就绪'), findsOneWidget);
    expect(find.byKey(const ValueKey('mediapipe-delete')), findsOneWidget);
    expect(File(service.modelPathFor(descriptor)).existsSync(), isTrue);
    expect(toasts.history.first.title, '本地语义模型已就绪');
    expect(tester.takeException(), isNull);
  });

  testWidgets('校验失败：提示重试且不留坏文件', (tester) async {
    final dir = _tempDir();
    final service = _service(dir, MockClient.streaming((req, body) async {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('tampered bytes')),
        200,
      );
    }));
    // 期望值与服务端内容不一致 → sha256_mismatch。
    final descriptor = _descriptor(sha256Hex(utf8.encode(_payload)));
    final toasts = ToastService(autoDismiss: false);

    await tester.pumpWidget(_wrap(MediaPipeModelCard(
      service: service,
      model: descriptor,
      toasts: toasts,
    )));
    await _flush(tester);

    await tester.tap(find.byKey(const ValueKey('mediapipe-download')));
    await tester.pump();
    await _settleIo(tester);

    expect(find.text('模型文件校验失败，已删除，请重试'), findsOneWidget);
    expect(find.text('未下载'), findsOneWidget);
    expect(File(service.modelPathFor(descriptor)).existsSync(), isFalse,
        reason: '校验失败的文件必须删除');
    expect(toasts.history.first.title, '模型文件校验失败，已删除，请重试');
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除：文件消失并回到未下载', (tester) async {
    final dir = _tempDir();
    final descriptor = _descriptor(sha256Hex(utf8.encode(_payload)));
    final service = _service(dir, MockClient((req) async => http.Response('', 500)));
    final path = service.modelPathFor(descriptor);
    Directory(File(path).parent.path).createSync(recursive: true);
    File(path).writeAsStringSync('present');

    final toasts = ToastService(autoDismiss: false);
    await tester.pumpWidget(_wrap(MediaPipeModelCard(
      service: service,
      model: descriptor,
      toasts: toasts,
    )));
    await _flush(tester);

    expect(find.text('已就绪'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mediapipe-delete')));
    await tester.pump();
    await _settleIo(tester);

    expect(File(path).existsSync(), isFalse);
    expect(find.text('未下载'), findsOneWidget);
    expect(toasts.history.first.title, '已删除本地模型');
    expect(tester.takeException(), isNull);
  });

  testWidgets('平台不支持：禁用下载并说明原因', (tester) async {
    final dir = _tempDir();
    final service = _service(
      dir,
      MockClient((req) async => http.Response('', 500)),
      supported: false,
    );
    await tester.pumpWidget(_wrap(MediaPipeModelCard(
      service: service,
      model: _descriptor(sha256Hex(utf8.encode(_payload))),
      toasts: ToastService(autoDismiss: false),
    )));
    await _flush(tester);

    expect(find.text('当前设备不支持'), findsOneWidget);
    expect(find.byKey(const ValueKey('mediapipe-download')), findsNothing);
    expect(find.textContaining('当前设备不在官方支持范围内'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
