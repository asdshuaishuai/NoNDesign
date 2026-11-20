// 四模块同一案例无人值守验收（debug 构建 + VM Service）。
// 用法：dart run tool/vm_regression_driver.dart <ws://VM Service URI>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kCase =
    '做一个待办清单应用：支持新增、勾选完成、删除，移动端优先，风格现代克制。';

class VmClient {
  VmClient(this._ws);
  final WebSocket _ws;
  int _id = 0;
  final _pending = <String, Completer<dynamic>>{};

  static Future<VmClient> connect(String uri) async {
    final ws = await WebSocket.connect(uri);
    final c = VmClient(ws);
    ws.listen((data) {
      final m = jsonDecode(data as String) as Map<String, dynamic>;
      final id = m['id'];
      if (id != null) {
        final p = c._pending.remove(id);
        if (p != null) {
          if (m['error'] != null) {
            p.completeError(Exception(jsonEncode(m['error'])));
          } else {
            p.complete(m['result']);
          }
        }
      }
    });
    return c;
  }

  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    final id = '${_id++}';
    final c = Completer<dynamic>();
    _pending[id] = c;
    _ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(minutes: 2));
  }
}

Future<dynamic> eval(VmClient vm, String isolateId, String libraryId,
    String expr, List<String> log) async {
  final r = await vm.call('evaluate', {
    'isolateId': isolateId,
    'targetId': libraryId,
    'expression': expr,
    'disableBreakpoints': true,
  });
  final ref = r; // call() 已解包 RPC result
  if (ref is Map) {
    if (ref['valueAsString'] != null) return ref['valueAsString'];
    final dump = jsonEncode(ref);
    log.add('[eval] non-value: '
        '${dump.length > 400 ? dump.substring(0, 400) : dump}');
    stdout.writeln(log.last);
    return null;
  }
  return ref;
}

Future<void> main(List<String> args) async {
  final uri = args.first;
  final report = File(r'D:/workplace/nan/diag/module_regression.md');
  final lines = <String>[];
  void sink(String line) {
    lines.add(line);
    stdout.writeln(line);
  }

  Future<void> flushReport() async {
    await report.writeAsString(lines.join('\n'));
  }

  sink('# 四模块同一案例回归（$kCase）');
  sink('');
  final vm = await VmClient.connect(uri);
  final vm0 = await vm.call('getVM');
  final isolateId = (vm0['isolates'] as List).first['id'];
  final iso = await vm.call('getIsolate', {'isolateId': isolateId});
  String? storeLib;
  for (final lib in (iso['libraries'] as List)) {
    final u = (lib['uri'] ?? '').toString();
    if (u.endsWith('core/store.dart')) {
      storeLib = lib['id'];
      break;
    }
  }
  sink('- isolate: `$isolateId`, store lib: `$storeLib`');
  if (storeLib == null) {
    sink('**失败：找不到 store.dart 库**');
    await flushReport();
    exit(2);
  }

  // 自动化前强制解锁（热重载/中断可能留下卡死锁；生产由 35 分钟自愈兜底）。
  await eval(vm, isolateId, storeLib, 'AppStore.debugInstance!.debugForceIdle()', lines);
  var ready = false;
  for (var i = 0; i < 60; i++) {
    final v = await eval(
        vm, isolateId, storeLib, 'AppStore.debugInstance != null', lines);
    if (v == 'true' || v == true) {
      ready = true;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  sink(ready ? '- debugInstance: 就绪' : '**失败：debugInstance 未就绪**');
  if (!ready) {
    await flushReport();
    exit(2);
  }

  final modules = args.length > 1
      ? args[1].split(',')
      : const <String>['design', 'three', 'video', 'hotapp'];
  final summary = <String>[];
  for (final mode in modules) {
    sink('');
    sink('## 模块 $mode');
    final t0 = DateTime.now();
    await eval(vm, isolateId, storeLib,
        "AppStore.debugInstance!.debugRunModule('$mode', '$kCase')", lines);
    String? verdict;
    for (var i = 0; i < 600; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      verdict = await eval(vm, isolateId, storeLib,
          'AppStore.debugInstance!.debugRunVerdict', lines);
      if (verdict == 'true' || verdict == 'false') break;
    }
    final dt = DateTime.now().difference(t0);
    final ok = verdict == 'true';
    sink('- 终态: ${ok ? '✅ 成功' : '❌ 失败'} verdict=$verdict 用时 ${dt.inSeconds}s');
    summary.add('| $mode | ${ok ? '✅' : '❌'} | ${dt.inSeconds}s |');
    if (!ok) {
      final detail = await eval(
          vm,
          isolateId,
          storeLib,
          'AppStore.debugInstance!.chatMessages.isEmpty '
              '? "no-messages" '
              ': AppStore.debugInstance!.chatMessages.last.detail ?? '
                  'AppStore.debugInstance!.chatMessages.last.text',
          lines);
      sink('- 失败上下文: $detail');
    }
  }
  sink('');
  sink('| 模块 | 终态 | 用时 |');
  sink('|---|---|---|');
  for (final row in summary) {
    sink(row);
  }
  await flushReport();
  exit(lines.join().contains('❌') ? 1 : 0);
}
