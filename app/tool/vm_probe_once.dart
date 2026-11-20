// 一次性 VM eval 探针：验证连接 + debugInstance 读通路。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args.first);
  var id = 0;
  final pending = <String, Completer<dynamic>>{};
  ws.listen((d) {
    final m = jsonDecode(d as String) as Map<String, dynamic>;
    if (m['id'] != null) {
      pending.remove(m['id'])?.complete(m['error'] != null ? Exception(jsonEncode(m['error'])) : m['result']);
    }
  });
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    final i = '${id++}';
    final c = Completer<dynamic>();
    pending[i] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 20));
  }

  final vm = await call('getVM');
  final isolateId = (vm['isolates'] as List).first['id'];
  stdout.writeln('isolate=$isolateId');
  final iso = await call('getIsolate', {'isolateId': isolateId});
  String? lib;
  for (final l in (iso['libraries'] as List)) {
    if ((l['uri'] ?? '').toString().endsWith('core/store.dart')) {
      lib = l['id'];
      break;
    }
  }
  stdout.writeln('storeLib=$lib');
  Future<dynamic> ev(String e) => call('evaluate', {
        'isolateId': isolateId,
        'targetId': lib,
        'expression': e,
        'disableBreakpoints': true,
      });
  final r1 = await ev('AppStore.debugInstance != null');
  stdout.writeln('r1=${jsonEncode(r1)}');
  final r2 = await ev('AppStore.debugInstance?.chatMessages.length');
  stdout.writeln('r2=${jsonEncode(r2)}');
  exit(0);
}
