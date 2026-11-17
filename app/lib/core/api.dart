import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

import 'package:http/http.dart' as http;

class ServerHandle {
  final String baseUrl;
  final Process? process;
  final List<String> logs;
  ServerHandle(this.baseUrl, this.process, this.logs);

  void dispose() {
    process?.kill(ProcessSignal.sigterm);
  }
}

class ServerLauncher {
  /// 手动指定的服务器地址（手机「连接桌面」模式）：设置面板写入，launch
  /// 优先于环境变量与本地 spawn——移动端无法跑 Python 服务器。
  static String? manualBaseUrl;

  static Future<ServerHandle> launch() async {
    final manual = manualBaseUrl;
    if (manual != null && manual.isNotEmpty) {
      // 单/多尾斜杠都剥干净再进 handle：_healthy 自行剥斜杠所以健康检查
      // 能过，但保留斜杠的 baseUrl 会让之后所有路径变成 //path 而 404
      //（移动端「连接桌面」死锁在误导性 no models in registry）。
      final url = manual.replaceAll(RegExp(r'/+$'), '');
      final ok = await _healthy(url, attempts: 4);
      if (ok) return ServerHandle(url, null, ['using manual server ($url)']);
      throw StateError('指定的服务器不可达：$url（检查桌面端是否在运行、两机是否同一网络）');
    }
    final envUrl = Platform.environment['NONDESIGN_SERVER'];
    if (envUrl != null && envUrl.isNotEmpty) {
      final ok = await _healthy(envUrl, attempts: 12);
      if (ok) return ServerHandle(envUrl.replaceAll(RegExp(r'/+$'), ''), null, ['using NONDESIGN_SERVER']);
    }

    final root = _findRoot();
    if (root == null) {
      throw StateError('server/main.py not found; set NONDESIGN_SERVER or run from the repo');
    }
    // 偶发竞态自愈（2026-11-16 真机弹窗实证：旧实例退出与 spawn 交错的窗口
    // 里端口文件/看门狗互踩，一次 spawn 失败）：清场后重试一次再报错。
    try {
      return await _spawnFromRoot(root);
    } on StateError {
      final metaFile = File('${Platform.environment['HOME']}/.nondesign/server.json');
      try {
        if (metaFile.existsSync()) metaFile.deleteSync();
      } catch (_) {}
      return await _spawnFromRoot(root);
    }
  }

  static Future<ServerHandle> _spawnFromRoot(String root) async {
    final python = _findPython(root);
    final logs = <String>[];
    // A stale port file from a previous run can otherwise win the race and
    // point the app at a dead server before the new one writes its port.
    final metaFile = File('${Platform.environment['HOME']}/.nondesign/server.json');
    try {
      if (metaFile.existsSync()) metaFile.deleteSync();
    } catch (_) {}
    final startedAt = DateTime.now();
    final process = await Process.start(
      python,
      [File('$root/server/main.py').path, '--port', '0'],
      workingDirectory: root,
      environment: {'PYTHONUNBUFFERED': '1', 'NONDESIGN_PARENT_PID': '$pid'},
    );
    final completer = Completer<String>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      logs.add(line);
      final match = RegExp(r'listening on http://127\.0\.0\.1:(\d+)').firstMatch(line);
      if (match != null && !completer.isCompleted) {
        completer.complete('http://127.0.0.1:${match.group(1)}');
      }
    });
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(logs.add);

    // The port file is a second discovery channel (stdout can be buffered by a
    // wrapper in packaged builds).
    unawaited(() async {
      for (var i = 0; i < 40 && !completer.isCompleted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        try {
          if (!metaFile.existsSync()) continue;
          if (metaFile.statSync().modified.isBefore(startedAt.subtract(const Duration(seconds: 1)))) continue;
          final data = jsonDecode(await metaFile.readAsString()) as Map;
          final port = data['port'];
          if (port is num) completer.complete('http://127.0.0.1:${port.toInt()}');
        } catch (_) {}
      }
    }());

    final baseUrl = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw StateError('server did not start:\n${logs.join('\n')}');
      },
    );
    if (!await _healthy(baseUrl, attempts: 20)) {
      throw StateError('server health check failed:\n${logs.join('\n')}');
    }
    return ServerHandle(baseUrl, process, logs);
  }

  static String? _findRoot() {
    final candidates = <String>[
      Platform.environment['NONDESIGN_ROOT'] ?? '',
      Directory.current.path,
      Directory.current.parent.path,
    ];
    for (final c in candidates) {
      if (c.isEmpty) continue;
      if (File('$c/server/main.py').existsSync()) return c;
    }
    // Dev builds live under app/build/...; walk up from the executable so
    // `open build/.../NoNDesign.app` still finds the repo server.
    Directory? dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 10 && dir != null; i++) {
      if (File('${dir.path}/server/main.py').existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static String _findPython(String root) {
    final env = Platform.environment['NONDESIGN_PYTHON'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final venv = '$root/.venv/bin/python';
    if (File(venv).existsSync()) return venv;
    if (File('/opt/homebrew/bin/python3').existsSync()) return '/opt/homebrew/bin/python3';
    return 'python3';
  }

  static Future<bool> _healthy(String baseUrl, {int attempts = 1}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final res = await http
            .get(Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/health'))
            .timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body) as Map;
          if (body['ok'] == true) return true;
        }
      } catch (e) {
        print('[nondesign] health $baseUrl error: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }
}

class NoNDesignApi {
  final String baseUrl;
  final http.Client _client;

  /// SSE 流中空闲超时：两行事件之间超过该时长视为服务端卡死（进程活、
  /// 不发数据），收流并合成 failed 终态——否则 await for 永挂、客户端
  /// agentBusy 永真。默认对齐 ACP 服务端自身的 600s 每事件等待预算再留
  /// 余量（合法长操作——LLM 调用/引擎渲染——都在事件间远小于此值）；
  /// 测试可缩短。
  static Duration sseIdleTimeout = const Duration(seconds: 660);

  /// LLM 生成类端点（3D 新建项目/跑层）的客户端超时：服务端整份生成
  /// （spec JSON / scene.js，thinking_level 还透传 reasoning_effort）经常
  /// 超过 postJson 默认的 30s——客户端先抛 TimeoutException 报「生成失败」，
  /// 服务端却继续跑完落盘，重试撞 project_exists / pass_awaiting_feedback，
  /// UI 认知与盘上状态分叉。默认 10 分钟（对齐 hotAppGenerate/hotAppRefine；
  /// 服务端自身 _chat 用 AsyncOpenAI 默认 600s 无上限）；测试可缩短。
  static Duration llmGenTimeout = const Duration(minutes: 10);

  NoNDesignApi(this.baseUrl, [http.Client? client]) : _client = client ?? http.Client();

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> getJson(String path, {Duration timeout = const Duration(seconds: 20)}) async {
    final res = await _client.get(_uri(path)).timeout(timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final res = await _client
        .post(_uri(path), headers: {'content-type': 'application/json'}, body: jsonEncode(body))
        .timeout(timeout);
    return _decode(res);
  }


  // ---- ACP 外部智能体 ----

  Future<List<AcpAgentInfo>> acpAgents({bool probe = false}) async {
    final res = await getJson('/acp/agents${probe ? '?probe=1' : ''}');
    return ((res['agents'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => AcpAgentInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Map<String, dynamic>> acpNewSession(String agent, String? cwd) =>
      postJson('/acp/session', {'agent': agent, if (cwd != null) 'cwd': cwd});

  /// ACP prompt 的 SSE 流——事件形状与 /agent/run 同族（assistant_delta /
  /// thinking_delta / tool_start / tool_end / note / done / failed）。
  Stream<Map<String, dynamic>> acpPrompt(String sessionId, String text) async* {
    final request = http.Request('POST', _uri('/acp/prompt'))
      ..headers['accept'] = 'text/event-stream'
      ..body = jsonEncode({'session_id': sessionId, 'text': text});
    final response = await _client.send(request).timeout(const Duration(seconds: 660));
    if (response.statusCode != 200) {
      yield {'type': 'failed', 'error': 'acp_http_${response.statusCode}', 'stopReason': 'failed'};
      return;
    }
    var stalled = false;
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(sseIdleTimeout, onTimeout: (sink) {
      stalled = true;
      sink.close(); // 结束收流：下方合成 failed 终态
    });
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final value = jsonDecode(payload);
        if (value is Map<String, dynamic>) {
          yield value;
          if (value['type'] == 'done' || value['type'] == 'failed') return;
        }
      } catch (_) {}
    }
    if (stalled) {
      yield {'type': 'failed', 'error': 'sse_idle_timeout', 'stopReason': 'failed'};
    }
  }

  Future<void> acpCancel(String sessionId) async {
    try {
      await postJson('/acp/cancel', {'session_id': sessionId});
    } catch (_) {}
  }

  Future<void> acpClose(String sessionId) async {
    try {
      await postJson('/acp/close', {'session_id': sessionId});
    } catch (_) {}
  }

  Map<String, dynamic> _decode(http.Response res) {
    dynamic value;
    if (res.body.isNotEmpty) {
      try {
        value = jsonDecode(res.body);
      } catch (_) {
        value = null; // 非 JSON body（代理错误页/纯文本 500）不抛 FormatException
      }
    }
    final okStatus = res.statusCode >= 200 && res.statusCode < 300;
    if (!okStatus) {
      String detail;
      if (value is Map) {
        detail = (value['detail'] ?? value['error'] ?? res.body).toString();
      } else {
        final text = res.body.trim();
        detail = text.isEmpty ? 'HTTP ${res.statusCode}' : text;
      }
      if (detail.length > 500) detail = '${detail.substring(0, 500)}…';
      return {'ok': false, 'status': res.statusCode, 'detail': detail};
    }
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value == null && res.body.isEmpty) return {'ok': false, 'error': 'empty_response'};
    return {'ok': false, 'error': 'unexpected_response', 'status': res.statusCode};
  }

  Future<Map<String, dynamic>> health() => getJson('/health');
  Future<Map<String, dynamic>> models() => getJson('/models');
  Future<Map<String, dynamic>> refreshModels() => postJson('/models/refresh', const {});
  Future<List<dynamic>> templates() async => (await getJson('/engine/templates'))['templates'] ?? const [];
  Future<List<dynamic>> components() async => (await getJson('/engine/components'))['components'] ?? const [];
  Future<List<dynamic>> themes() async => (await getJson('/engine/themes'))['themes'] ?? const [];

  Future<Map<String, dynamic>> render(String mbt) => postJson('/engine/render', {'mbt': mbt});
  Future<Map<String, dynamic>> validate(String mbt) => postJson('/engine/validate', {'mbt': mbt});
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) =>
      postJson('/engine/apply', {'mbt': mbt, 'op': op, 'gate': gate});
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      postJson('/engine/session', {'mbt': mbt, 'name': name, if (arg != null) 'arg': arg});
  Future<Map<String, dynamic>> generate(String mbt, String intent, String name, Map<String, dynamic> spec) =>
      postJson('/engine/generate', {'mbt': mbt, 'intent': intent, 'name': name, 'spec': spec});
  Future<Map<String, dynamic>> exportHtml(String mbt) => postJson('/engine/export-html', {'mbt': mbt});

  /// Figma 双向包（客户端插件能力，与引擎解耦）：board-*.svg 拖入即
  /// 矢量图层，nondesign.json 走 figma-plugin 建可编辑图层。服务器落盘。
  Future<Map<String, dynamic>> exportFigma(String mbt) =>
      postJson('/project/export/figma', {'mbt': mbt});

  // ---------- 轨道 C：3D 制作工作台（应用内 WebView 即执行面） ----------

  /// 生成整份 spec JSON 是分钟级 LLM 调用——10 分钟超时（llmGenTimeout），
  /// 不用 postJson 默认 30s（否则客户端先失败、服务端照常落盘，状态分叉）。
  Future<Map<String, dynamic>> threeNewProject({
    required String name, required String brief,
    required String model, required String baseUrl,
    required String apiKey, required String thinkingLevel,
  }) => postJson('/three/project/new', {
        'name': name, 'brief': brief, 'model': model, 'base_url': baseUrl,
        'api_key': apiKey, 'thinking_level': thinkingLevel,
      }, timeout: llmGenTimeout);

  /// 跑一层同样是分钟级 LLM 调用（整文件 scene.js）——同 threeNewProject。
  Future<Map<String, dynamic>> threeRunPass({
    required String name, required String model, required String baseUrl,
    required String apiKey, required String thinkingLevel,
  }) => postJson('/three/pass', {
        'name': name, 'model': model, 'base_url': baseUrl,
        'api_key': apiKey, 'thinking_level': thinkingLevel,
      }, timeout: llmGenTimeout);

  Future<Map<String, dynamic>> threeFeedback(String name, String kind, [Object? payload]) =>
      postJson('/three/feedback', {'name': name, 'kind': kind, if (payload != null) 'payload': payload});

  Future<Map<String, dynamic>> threeContinue(String name, [String summary = '']) =>
      postJson('/three/continue', {'name': name, 'summary': summary});

  Future<Map<String, dynamic>> threeProject(String name) => getJson('/three/project?name=${Uri.encodeQueryComponent(name)}');
  Future<Map<String, dynamic>> threeProjects() => getJson('/three/projects');

  /// 应用内 WebView 的执行面 URL（服务器实时 serve 的 three.js 预览页）。
  String threePreviewUrl(String name) => '$baseUrl/three/preview/${Uri.encodeQueryComponent(name)}';

  // ---------- NoN 热应用引擎 + 作品集 ----------

  Future<Map<String, dynamic>> hotAppGenerate({
    required String name, required String brief,
    required String model, required String baseUrl, required String apiKey,
  }) => postJson('/hotapp/generate', {
        'name': name, 'brief': brief, 'model': model,
        'base_url': baseUrl, 'api_key': apiKey,
      }, timeout: const Duration(minutes: 10));

  Future<Map<String, dynamic>> hotAppRefine({
    required String name, required String instruction,
    required String model, required String baseUrl, required String apiKey,
  }) => postJson('/hotapp/refine', {
        'name': name, 'instruction': instruction, 'model': model,
        'base_url': baseUrl, 'api_key': apiKey,
      }, timeout: const Duration(minutes: 10));

  Future<Map<String, dynamic>> hotAppList() => getJson('/hotapp/list');
  Future<Map<String, dynamic>> hotAppDelete(String name) =>
      postJson('/hotapp/delete', {'name': name});

  /// NoN 热应用的执行面 URL（自包含动画 HTML，WebView 即运行时）。
  String hotAppPageUrl(String name) => '$baseUrl/hotapp/page/${Uri.encodeQueryComponent(name)}';

  Future<Map<String, dynamic>> portfolio() => getJson('/portfolio');
  Future<Map<String, dynamic>> portfolioDelete(String kind, String ref) =>
      postJson('/portfolio/delete', {'kind': kind, 'ref': ref});

  /// Layout intent (session_constrain): `intent` is a phrase like 居中 / 等间距 /
  /// 网格 3. Engine returns a canonical envelope {ok, id, x, mbt} — no render
  /// face; cannot_parse failures carry the intent vocabulary in `error`.
  Future<Map<String, dynamic>> constrainIntent(String mbt, String ab, String intent) =>
      postJson('/engine/constrain', {'mbt': mbt, 'artboard': ab, 'intent': intent});

  /// Demo-mode gesture (session_event). `spec` is a raw event token (e.g.
  /// `key_enter`), not JSON. Envelope matches tap: {ok, changes[], current, mbt}.
  Future<Map<String, dynamic>> event(String mbt, String ab, String spec) =>
      postJson('/engine/event', {'mbt': mbt, 'artboard': ab, 'spec': spec});

  /// Engine version control (session_history). `command` is the sub-command
  /// expression: `init <board>`, `commit`, `log`, `undo`, `redo`, `diff <from> <to>`.
  Future<Map<String, dynamic>> history(String mbt, String command) =>
      postJson('/engine/history', {'mbt': mbt, 'command': command});

  Future<Map<String, dynamic>> saveProject({
    required String mbt,
    required String path,
    String password = '',
    required Map<String, dynamic> docs,
  }) =>
      postJson('/project/save', {'mbt': mbt, 'path': path, 'password': password, 'docs': docs});

  Future<Map<String, dynamic>> openProject(String path, {String password = ''}) =>
      postJson('/project/open', {'path': path, 'password': password});

  Future<List<dynamic>> listProjects([String? dir]) async {
    final suffix = dir == null ? '' : '?dir=${Uri.encodeQueryComponent(dir)}';
    return (await getJson('/project/list$suffix'))['projects'] ?? const [];
  }

  Future<Map<String, dynamic>> clearSession(String key) =>
      postJson('/agent/session/clear', {'key': key});

  Future<bool> cancelAgent(int runId) async {
    final res = await postJson('/agent/cancel', {'run_id': runId});
    return res['ok'] == true;
  }

  /// SSE stream. Emits decoded JSON events, then closes at done/failed.
  Stream<Map<String, dynamic>> agentRun(Map<String, dynamic> body) async* {
    final request = http.Request('POST', _uri('/agent/run'));
    request.headers['content-type'] = 'application/json';
    request.headers['accept'] = 'text/event-stream';
    request.body = jsonEncode(body);
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 30));
    } catch (e) {
      yield {'type': 'failed', 'error': 'agent_connect_failed: $e', 'stopReason': 'failed'};
      return;
    }
    if (response.statusCode != 200) {
      yield {'type': 'failed', 'error': 'agent_http_${response.statusCode}', 'stopReason': 'failed'};
      return;
    }
    var stalled = false;
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(sseIdleTimeout, onTimeout: (sink) {
      stalled = true;
      sink.close(); // 结束收流：下方合成 failed 终态
    });
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        // dart:convert 对 JSON 对象本来就产出 Map<String, dynamic>——
        // 直接窄化，别再做整表拷贝（思考/文档流式每秒几十个分片）。
        final value = jsonDecode(payload);
        if (value is Map<String, dynamic>) {
          yield value;
          if (value['type'] == 'done' || value['type'] == 'failed') return;
        }
      } catch (_) {
        // ignore malformed SSE line
      }
    }
    if (stalled) {
      // 流中空闲超时（服务端进程活但不再发数据）：合成终态，await for 的
      // 消费方（store._runAgent）才不会永挂、agentBusy 才会释放。
      yield {'type': 'failed', 'error': 'sse_idle_timeout', 'stopReason': 'failed'};
    }
  }
}
