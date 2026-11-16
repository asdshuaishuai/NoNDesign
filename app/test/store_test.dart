// store.dart 核心写路径的单测——审查发现 applyOp/_commit/undo/redo 等方法
// 完全零测试覆盖（2026-11-14）。用真实 HttpServer 模拟 /engine/apply 与
// /engine/render，按 api_test.dart 已验证的模式路由响应体。
// 2026-11-17 核心状态机批次补：op 串行队列回归锚（两 op 在飞被串行化、
// 第二条用刷新后的 mbt）、constrainLayout/⌘Z/engineHistory 入队、
// newProject/openProject 的 agentBusy 门与 run 归属校验、doc_delta 定时器
// 的 dispose 生命周期、SSE 空闲超时释放 agentBusy、run 起点等待队列、
// recovery 快照串行写链。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';

/// 启一个按请求路径分发固定/动态响应的本地 HTTP mock，返回 base URL 与关闭回调。
/// handler 可为异步（在飞挂起模拟慢 HTTP）。
Future<(String, Future<void> Function())> _mockServer(
  Map<String, FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> body)> routes,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final chunks = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    final body = chunks.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
    final handler = routes[request.uri.path];
    final out = handler == null ? {'ok': false, 'error': 'no_route'} : await handler(body);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(out));
    await request.response.close();
  });
  return ('http://127.0.0.1:${server.port}', () => server.close(force: true));
}

/// /agent/run 的 SSE mock（原始 ServerSocket + 手写 chunked 编码）：
/// 事件由 [script] 经 send 逐条发出——本机 dart:io 的 HttpResponse.flush()
/// 不把字节推上网络（数据压到 close 才到），HttpServer mock 无法模拟
/// 「连接活着、事件逐条到达」；原始 socket 的 flush 真正落线。
/// script 卡住不返回 = 服务端进程活但不发数据（空闲超时用例）；
/// script 正常返回 = 发终止块并断开。
Future<(String, Future<void> Function())> _sseServer(
  Future<void> Function(Future<void> Function(Map<String, dynamic> ev) send) script,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <Socket>[];
  final sub = server.listen((socket) {
    sockets.add(socket);
    socket.listen((_) {}); // 请求头/body 排掉（客户端不等待响应体回读）
    socket.write('HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n');
    Future<void> send(Map<String, dynamic> ev) async {
      final data = utf8.encode('data: ${jsonEncode(ev)}\n\n');
      socket.add(utf8.encode('${data.length.toRadixString(16)}\r\n'));
      socket.add(data);
      socket.add(utf8.encode('\r\n'));
      await socket.flush();
    }

    unawaited(socket.flush().then((_) => script(send)).then((_) async {
      socket.add(utf8.encode('0\r\n\r\n'));
      await socket.flush();
      socket.destroy();
    }));
  });
  return (
    'http://127.0.0.1:${server.port}',
    () async {
      await sub.cancel();
      for (final s in sockets) {
        try {
          s.destroy();
        } catch (_) {}
      }
      await server.close();
    },
  );
}

/// 武装一个能通过 _runAgent 前置门的 store（api + 单模型 registry + key），
/// recovery 落测试临时目录（不污染真实 ~/.nondesign）。
AppStore _runReadyStore(String base, String recoveryDir) {
  final store = AppStore();
  store.api = NoNDesignApi(base);
  store.recoveryDir = recoveryDir;
  store.registry = ModelRegistry.fromJson({
    'providers': {
      'testp': {
        'api': base,
        'protocol': 'openai',
        'models': {
          'm1': {'name': 'M1', 'tool_call': true, 'limit': {'context': 128000}},
        },
      },
    },
  });
  store.settings.apiKey = 'test-key';
  store.settings.providerId = 'testp';
  store.settings.modelId = 'm1';
  return store;
}

Directory _tempRecoveryDir() {
  final dir = Directory.systemTemp.createTempSync('nondesign-store-test');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
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

  // ---- 2026-11-17 核心状态机批次回归锚 ----

  test('two in-flight applyOps are serialized — the second reads the refreshed mbt', () async {
    // 丢更新修复的核心机制锚点（此前队列被回退成直发 await 不会有任何测试变红）：
    // 第一条 op 的 HTTP 在飞挂起期间，第二条必须排队；放行后第二条以第一条
    // _commit 完成的 mbt 为基底，而非调用期的陈旧值。
    final received = <String>[];
    final gate = Completer<void>();
    final (base, close) = await _mockServer({
      '/engine/apply': (body) async {
        received.add(body['mbt'] as String);
        if (received.length == 1) await gate.future; // 第一条在飞挂起
        return _envelope(mbt: 'MBT_V${received.length + 1}');
      },
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;

    final op1 = store.applyOp('op one');
    final op2 = store.applyOp('op two'); // 不等 op1：应排队
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(received, ['MBT_V1'], reason: '在飞窗口内第二条 op 不得发出');

    gate.complete();
    expect(await op1, true);
    expect(await op2, true);
    expect(received, ['MBT_V1', 'MBT_V2'], reason: '第二条必须以刷新后的 mbt 为基底');
    expect(store.mbt, 'MBT_V3');
    await close();
  });

  test('undo issued while an op is in flight is queued and lands on the committed history', () async {
    // 已知缺口②：⌘Z 在 op 在飞时调用期急算 historyIndex-1 会读到旧下标，
    // 轻则与 op 合并成一步、重则撤销直接丢失。排队后目标下标在链内计算。
    final (base, close) = await _mockServer({
      '/engine/apply': (body) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return _envelope(mbt: 'MBT_V2');
      },
      '/engine/render': (body) => _envelope(mbt: body['mbt'] as String),
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;

    final op = store.applyOp('op'); // 在飞：150ms 后提交 MBT_V2
    await Future<void>.delayed(const Duration(milliseconds: 30));
    store.undo(); // op 尚未提交（historyIndex 仍是 0）
    await op;
    await store.opQueueIdle;

    expect(store.mbt, 'MBT_V1'); // 撤销作用于提交后的历史，而不是丢失
    expect(store.historyIndex, 0);
    await close();
  });

  test('constrainLayout queues behind an in-flight applyOp and uses the refreshed mbt', () async {
    final constrainMbt = <String>[];
    final gate = Completer<void>();
    final (base, close) = await _mockServer({
      '/engine/apply': (body) async {
        await gate.future;
        return _envelope(mbt: 'MBT_V2');
      },
      '/engine/constrain': (body) {
        constrainMbt.add(body['mbt'] as String);
        return {'ok': true, 'mbt': 'MBT_C'};
      },
      '/engine/render': (body) => _envelope(mbt: body['mbt'] as String),
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;
    store.hasProject = true;
    store.activeBoard = 'home';

    final op = store.applyOp('op');
    final constrained = store.constrainLayout('居中');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(constrainMbt, isEmpty, reason: '在飞 op 提交前不得发 constrain');

    gate.complete();
    expect(await op, true);
    expect(await constrained, true);
    expect(constrainMbt, ['MBT_V2']);
    expect(store.mbt, 'MBT_C');
    await close();
  });

  test('engineHistory undo/redo commits queue behind an in-flight applyOp', () async {
    final historyMbt = <String>[];
    final gate = Completer<void>();
    final (base, close) = await _mockServer({
      '/engine/apply': (body) async {
        await gate.future;
        return _envelope(mbt: 'MBT_V2');
      },
      '/engine/history': (body) {
        historyMbt.add(body['mbt'] as String);
        return {'ok': true, 'mbt': 'MBT_H'};
      },
      '/engine/render': (body) => _envelope(mbt: body['mbt'] as String),
    });
    final store = AppStore();
    store.api = NoNDesignApi(base);
    store.mbt = 'MBT_V1';
    store.history = ['MBT_V1'];
    store.historyIndex = 0;

    final op = store.applyOp('op');
    final hist = store.engineHistory('undo');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(historyMbt, isEmpty, reason: '在飞 op 提交前不得发 history');

    gate.complete();
    expect(await op, true);
    final res = await hist;
    expect(res['ok'], true);
    expect(historyMbt, ['MBT_V2']);
    expect(store.mbt, 'MBT_H'); // undo 的 canonical 已重渲染并提交
    await close();
  });

  test('newProject and openProjectPath are gated while an agent run is in flight', () async {
    // core-1：此前 newProject 无门且硬置 agentBusy=false——在飞 run 的
    // done/failed 事件随后把旧项目 canonical 提交进新项目。
    final store = AppStore();
    store.api = NoNDesignApi('http://127.0.0.1:1'); // 不起监听：到达即失败
    store.agentBusy = true;
    store.runId = 42;
    store.hasProject = true;
    store.projectName = 'old';
    store.mbt = 'OLD_MBT';

    expect(await store.newProject(name: 'x', empty: true), false);
    expect(await store.openProjectPath('/tmp/does-not-exist.ddp'), OpenResult.failed);

    // 在飞 run 的状态位与项目内容原样保留
    expect(store.agentBusy, true);
    expect(store.runId, 42);
    expect(store.projectName, 'old');
    expect(store.mbt, 'OLD_MBT');
  });

  test('a stalled agent stream releases agentBusy via the idle-timeout terminal', () async {
    // core-6：服务端进程活但不发数据 → await for 永挂、agentBusy 永真。
    // api 层空闲超时合成 failed 终态后，run 必须正常收尾。
    NoNDesignApi.sseIdleTimeout = const Duration(milliseconds: 250);
    addTearDown(() => NoNDesignApi.sseIdleTimeout = const Duration(seconds: 660));
    final (base, close) = await _sseServer((send) async {
      await send({'type': 'note', 'label': 'NoN 开始'});
      await Completer<void>().future; // 卡死：不再发任何行、也不关流
    });
    final store = _runReadyStore(base, _tempRecoveryDir().path);

    final ok = await store.runPlan('做个方案');

    expect(ok, false);
    expect(store.agentBusy, false);
    expect(store.agentError, contains('sse_idle_timeout'));
    await close();
  });

  test('run start drains the op queue so the run mbt snapshot is fresh', () async {
    // run 起点快照必须取在在飞 op 提交之后，否则服务端拿旧 canonical 干活、
    // 终态回来覆盖该 op（丢更新的 run 边界变体）。
    var runMbt = '';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final chunks = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      final body = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      if (request.uri.path == '/engine/apply') {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_envelope(mbt: 'MBT_V2')));
        await request.response.close();
        return;
      }
      runMbt = body['mbt'].toString();
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'done', 'text': 'ok', 'stopReason': 'done'})}\n\n');
      await request.response.close();
    });
    final store = _runReadyStore('http://127.0.0.1:${server.port}', _tempRecoveryDir().path);
    store.mbt = 'MBT_V1';

    final op = store.applyOp('op'); // 在飞：150ms 后提交 MBT_V2
    final ok = await store.runPlan('生成'); // 不等 op：起点必须等队列排空
    await op;

    expect(ok, true);
    expect(runMbt, 'MBT_V2', reason: 'run 起点快照必须取在 op 提交之后');
    await server.close(force: true);
  });

  test('orphaned run events are dropped — terminal canonical never commits', () async {
    // core-1 run 归属校验：SSE 事件不携带 run id，以 stream 启动时捕获的
    // runId 为归属令牌；令牌被换（项目切走等）后，旧 run 的 done canonical
    // 不得提交进当前项目。
    final requestSeen = Completer<void>();
    final release = Completer<void>();
    final (base, close) = await _sseServer((send) async {
      requestSeen.complete();
      await release.future;
      await send({
        'type': 'done',
        'text': 'ok',
        'stopReason': 'done',
        'mbt_b64': base64Encode(utf8.encode('ORPHAN_CANONICAL')),
      });
    });
    final store = _runReadyStore(base, _tempRecoveryDir().path);
    store.hasProject = true;
    store.mbt = 'NEW_PROJECT_MBT';

    final run = store.runPlan('做点什么');
    await requestSeen.future;
    store.runId = 999; // 模拟归属令牌被换（run 已废弃）
    release.complete();

    expect(await run, false);
    expect(store.mbt, 'NEW_PROJECT_MBT', reason: '废弃 run 的 canonical 不得提交');
    expect(store.agentBusy, false);
    await close();
  });

  test('pending doc_delta flush timer does not notify after dispose', () async {
    // core-4：doc_delta 的 80ms 合帧 timer 若不在 dispose 里 cancel，缓冲
    // 未冲刷时会在销毁后触发 _flushDoc → notifyListeners 于已销毁的
    // ChangeNotifier（debug 断言红）。
    final hold = Completer<void>();
    final (base, close) = await _sseServer((send) async {
      await send({'type': 'doc_delta', 'text': '部分文档正文'});
      await hold.future; // 流不结束：doc 缓冲保持未冲刷
    });
    final store = _runReadyStore(base, _tempRecoveryDir().path);
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final run = store.runPlan('写文档');
      await Future<void>.delayed(const Duration(milliseconds: 60)); // 事件已消费、timer 在飞
      store.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250)); // 80ms 到期点
      unawaited(run);
    }, (e, st) => errors.add(e));
    expect(errors, isEmpty, reason: 'dispose 后不得再触发 notifyListeners');
    await close();
  });

  test('concurrent persistRecovery writes serialize — intact JSON, last write wins', () async {
    // core-5：多处 unawaited 并发写同一 recovery.json，撕裂 JSON 会被
    // _loadRecovery 的 catch-all 静默吞掉。串行链保证后写完整覆盖先写。
    final dir = _tempRecoveryDir();
    final store = AppStore();
    store.recoveryDir = dir.path;
    store.hasProject = true;
    store.projectName = 'alpha';
    store.mbt = 'MBT_A';

    unawaited(store.debugPersistRecovery(force: true));
    store.projectName = 'beta';
    store.mbt = 'MBT_B';
    await store.debugPersistRecovery(force: true);
    await store.recoveryWritesIdle;

    final raw = jsonDecode(await File('${dir.path}/recovery.json').readAsString()) as Map<String, dynamic>;
    expect(raw['name'], 'beta');
    expect(raw['mbt'], 'MBT_B');
  });

  test('cancelAgent swallows network failures from the stop request', () async {
    // core-6 后半：/agent/cancel 的 SocketException/超时此前直接从按钮回调
    // 逸出为未处理异步异常；现在就地 toast。
    final store = AppStore();
    store.api = NoNDesignApi('http://127.0.0.1:1'); // 端口 1 无监听：连接拒绝（快速）
    store.agentBusy = true;
    store.runId = 7;

    await store.cancelAgent(); // 不得抛出

    expect(store.agentBusy, true); // 取消失败不影响在飞 run 状态
    expect(store.agentPhase, 'cancelling');
  });
}
