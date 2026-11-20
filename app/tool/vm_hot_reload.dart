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
      pending.remove(m['id'])?.complete(
          m['error'] != null ? Exception(jsonEncode(m['error'])) : m['result']);
    }
  });
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    final i = '${id++}';
    final c = Completer<dynamic>();
    pending[i] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 60));
  }
  final vm = await call('getVM');
  final isolateId = (vm['isolates'] as List).first['id'];
  await call('reloadSources', {'isolateId': isolateId});
  stdout.writeln('reloaded ok');
  exit(0);
}
