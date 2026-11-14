// store.dart 核心写路径的单测——审查发现 applyOp/_commit/undo/redo 等方法
// 完全零测试覆盖（2026-11-14）。用真实 HttpServer 模拟 /engine/apply 与
// /engine/render，按 api_test.dart 已验证的模式路由响应体。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/store.dart';

/// 启一个按请求路径分发固定/动态响应的本地 HTTP mock，返回 base URL 与关闭回调。
Future<(String, Future<void> Function())> _mockServer(
  Map<String, Map<String, dynamic> Function(Map<String, dynamic> body)> routes,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final chunks = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    final body = chunks.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
    final handler = routes[request.uri.path];
    final out = handler == null ? {'ok': false, 'error': 'no_route'} : handler(body);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(out));
    await request.response.close();
  });
  return ('http://127.0.0.1:${server.port}', () => server.close(force: true));
}

Map<String, dynamic> _envelope({required String mbt, String entry = 'home'}) => {
      'ok': true,
      'mbt': mbt,
      'entry': entry,
      'revision': 1,
      'artboards': [
        {'id': entry, 'name': entry, 'width': 390, 'height': 844, 'nodes': []},
      ],
      'flows': [],
    };

void main() {
  // AppStore._toast 经 GlobalKey.currentState 需要一个已初始化的 WidgetsBinding，
  // 但该 binding 默认把本进程所有 HttpClient 请求拦截为 400（flutter_test 的
  // 防误连保护）——与本测试真实连 loopback mock server 冲突。显式还原真实
  // HttpOverrides，让 http 包的 dart:io 传输层直连本地端口。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('applyOp commits a successful envelope and pushes history', () async {
    final (base, close) = await _mockServer({
      '/engine/apply': (body) => _envelope(mbt: 'MBT_V2'),
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;

    final ok = await store.applyOp('move home n1 10 10');

    expect(ok, true);
    expect(store.mbt, 'MBT_V2');
    expect(store.history, ['MBT_V1', 'MBT_V2']);
    expect(store.historyIndex, 1);
    expect(store.dirty, true);
    expect(store.render.entry, 'home');
    await close();
  });

  test('applyOp leaves mbt/history untouched when the engine rejects the op', () async {
    final (base, close) = await _mockServer({
      '/engine/apply': (body) => {'ok': false, 'error': 'mbt_operation_unsupported'},
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;

    final ok = await store.applyOp('bogus-op', silent: true);

    expect(ok, false);
    expect(store.mbt, 'MBT_V1');
    expect(store.history, ['MBT_V1']);
    expect(store.historyIndex, 0);
    await close();
  });

  test('applyOp is rejected while an agent run is in flight', () async {
    final store = AppStore();
    store.api = NoNDesignApi('http://127.0.0.1:1');
    store.agentBusy = true;

    final ok = await store.applyOp('move home n1 0 0', silent: true);

    expect(ok, false);
  });

  test('undo then redo round-trips through history without re-fetching the same index twice', () async {
    final calls = <String>[];
    final (base, close) = await _mockServer({
      '/engine/render': (body) {
        calls.add(body['mbt'] as String);
        return _envelope(mbt: body['mbt'] as String);
      },
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V2';
    store.history = ['MBT_V1', 'MBT_V2'];
    store.historyIndex = 1;

    store.undo();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.mbt, 'MBT_V1');
    expect(store.historyIndex, 0);

    store.redo();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.mbt, 'MBT_V2');
    expect(store.historyIndex, 1);
    expect(calls, ['MBT_V1', 'MBT_V2']);
    await close();
  });

  test('undo is a no-op at the start of history (no network call, no state change)', () async {
    final store = AppStore();
    store.api = NoNDesignApi('http://127.0.0.1:1'); // 故意不起监听：到达即失败
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;

    store.undo();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(store.mbt, 'MBT_V1');
    expect(store.historyIndex, 0);
  });
}
