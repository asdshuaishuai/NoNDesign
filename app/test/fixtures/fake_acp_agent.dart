/// 假 ACP 智能体（集成测试夹具，纯 dart:io，零包依赖）。
///
/// 由 `app/test/acp_client_test.dart` 以 `dart <本文件>` 拉起，走真实的
/// newline-delimited JSON-RPC 管道：
///
/// ```
/// initialize → session/new → session/prompt
///   ├─ session/update (agent_message_chunk / tool_call / tool_call_update)
///   ├─ session/request_permission  →  校验应答形状（畸形即 exit 3）
///   ├─ fs/read_text_file（工作区内 / 越界各一次）
///   └─ fs/write_text_file（工作区内）
/// ```
///
/// 它把每一步的结果用正文片段回显给测试：
/// `第 N 轮开始` / `权限:selected:<optionId>` / `工作区内:<content>` /
/// `越界:blocked` / `写入:ok`。
///
/// 环境变量：
///  * `FAKE_ACP_EXIT_ON_PROMPT=1` —— 收到 prompt 立即退出（进程死亡路径）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

late IOSink _out;
final Map<int, Completer<Map<String, dynamic>>> _pending = <int, Completer<Map<String, dynamic>>>{};
var _nextAgentId = 100000;
String _sessionId = 'fake-session';
int _promptCount = 0;
int? _activePromptId;
bool _cancelled = false;

void main() {
  _out = stdout;
  final input = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  input.listen(_handleLine, onDone: () => exit(0));
}

void _write(Map<String, dynamic> message) {
  _out.writeln(jsonEncode(message));
}

void _notify(String method, Map<String, dynamic> params) {
  _write(<String, dynamic>{'jsonrpc': '2.0', 'method': method, 'params': params});
}

void _result(Object? id, Object? result) {
  _write(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});
}

void _error(Object? id, int code, String message) {
  _write(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'error': <String, dynamic>{'code': code, 'message': message},
  });
}

Future<Map<String, dynamic>> _request(String method, Map<String, dynamic> params) {
  _nextAgentId += 1;
  final id = _nextAgentId;
  final completer = Completer<Map<String, dynamic>>();
  _pending[id] = completer;
  _write(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
  return completer.future.timeout(const Duration(seconds: 40));
}

void _handleLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return;
  Map<String, dynamic> message;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return;
    message = Map<String, dynamic>.from(decoded);
  } catch (_) {
    return;
  }
  final id = message['id'];
  final method = message['method'];
  if (method is String) {
    final params = message['params'] is Map
        ? Map<String, dynamic>.from(message['params'] as Map)
        : <String, dynamic>{};
    if (id != null) {
      // 客户端 → 智能体请求。
      switch (method) {
        case 'initialize':
          _result(id, <String, dynamic>{
            'protocolVersion': 1,
            'agentInfo': <String, dynamic>{'name': 'Fake ACP', 'version': '1.0.0'},
          });
          return;
        case 'session/new':
          _result(id, <String, dynamic>{'sessionId': _sessionId});
          return;
        case 'session/prompt':
          _activePromptId = id is int ? id : int.tryParse('$id');
          unawaited(_runPrompt(id, params));
          return;
        default:
          _error(id, -32601, 'method not found: $method');
          return;
      }
    }
    // 通知（无 id）。
    if (method == 'session/cancel') {
      _cancelled = true;
      final active = _activePromptId;
      if (active != null) {
        _activePromptId = null;
        _chat('已取消');
        _result(active, <String, dynamic>{'stopReason': 'cancelled'});
      }
    }
    return;
  }
  // 客户端对智能体请求的应答。
  if (id is int) {
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final error = message['error'];
    if (error is Map) {
      completer.completeError(StateError('rpc error: ${error['code']}'));
      return;
    }
    completer.complete(message['result'] is Map
        ? Map<String, dynamic>.from(message['result'] as Map)
        : <String, dynamic>{'result': message['result']});
  }
}

void _chat(String text) {
  _notify('session/update', <String, dynamic>{
    'sessionId': _sessionId,
    'update': <String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    },
  });
}

Future<void> _runPrompt(Object? requestId, Map<String, dynamic> params) async {
  if (Platform.environment['FAKE_ACP_EXIT_ON_PROMPT'] == '1') {
    exit(7);
  }
  _promptCount += 1;
  _cancelled = false;
  final n = _promptCount;
  _chat('第 $n 轮开始');

  _notify('session/update', <String, dynamic>{
    'sessionId': _sessionId,
    'update': <String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': 'tool-$n',
      'title': '读取工作区文件',
      'kind': 'read',
    },
  });

  // 权限请求：应答形状是硬契约 `{"outcome":{"outcome":…,"optionId":…}}`。
  final permission = await _request('session/request_permission', <String, dynamic>{
    'sessionId': _sessionId,
    'toolCall': <String, dynamic>{'toolCallId': 'tool-$n', 'title': '读取工作区文件'},
    'options': <dynamic>[
      <String, dynamic>{'optionId': 'allow-once', 'name': '允许一次', 'kind': 'allow_once'},
      <String, dynamic>{'optionId': 'reject-once', 'name': '拒绝', 'kind': 'reject_once'},
    ],
  });
  final outcome = permission['outcome'];
  if (outcome is! Map || outcome['outcome'] is! String) {
    stderr.writeln('BAD_PERMISSION_SHAPE: ${jsonEncode(permission)}');
    exit(3);
  }
  final decision = outcome['outcome'] as String;
  final optionId = (outcome['optionId'] ?? '').toString();
  _chat('权限:$decision:$optionId');

  _notify('session/update', <String, dynamic>{
    'sessionId': _sessionId,
    'update': <String, dynamic>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'tool-$n',
      'status': 'completed',
      'title': '读取工作区文件',
    },
  });

  // fs 回调：工作区内一次读、一次写；越界读必须被拒绝。
  final workspace = Directory.current.path;
  final insidePath = '$workspace${Platform.pathSeparator}inside.txt';
  try {
    final inside = await _request('fs/read_text_file', <String, dynamic>{
      'sessionId': _sessionId,
      'path': insidePath,
    });
    _chat('工作区内:${(inside['content'] ?? '').toString().trim()}');
  } catch (error) {
    _chat('工作区内:error:${error.runtimeType}');
  }

  final outsidePath =
      '${Directory(workspace).parent.path}${Platform.pathSeparator}outside-secret.txt';
  try {
    final outside = await _request('fs/read_text_file', <String, dynamic>{
      'sessionId': _sessionId,
      'path': outsidePath,
    });
    // 到这里说明客户端放行了越界读取——测试会因此判红。
    _chat('越界:leaked:${outside['content']}');
  } catch (_) {
    _chat('越界:blocked');
  }

  try {
    await _request('fs/write_text_file', <String, dynamic>{
      'sessionId': _sessionId,
      'path': '$workspace${Platform.pathSeparator}note.txt',
      'content': 'from agent',
    });
    _chat('写入:ok');
  } catch (error) {
    _chat('写入:error:${error.runtimeType}');
  }

  if (_cancelled) {
    _activePromptId = null;
    _result(requestId, <String, dynamic>{'stopReason': 'cancelled'});
    return;
  }
  _activePromptId = null;
  _result(requestId, <String, dynamic>{'stopReason': 'end_turn'});
}
