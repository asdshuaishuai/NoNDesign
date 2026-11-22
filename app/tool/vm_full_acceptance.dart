// 四模块 + 热应用双路径验收（VM Service 直驱，无人值守）。
// 用法：dart run tool/vm_full_acceptance.dart <ws://VM URI> [steps]
//   steps: design,proto,three,video,hotapp（逗号分隔，缺省全跑）
// 每步记录终态与产物，汇总落盘 diag/full_acceptance.md。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kCaseDesign =
    '做一个待办清单应用：支持新增、勾选完成、删除，移动端优先，风格现代克制。';
const String kCaseThree =
    '做一个悬浮卡片展示的 3D 场景：三张卡片在深色星空背景下缓慢环绕漂浮，'
    '鼠标可旋转视角，点击卡片会放大，整体风格现代克制。';
const String kCaseVideo =
    '做一个 6 秒的产品标语代码动画：文字从模糊到清晰，背景粒子缓慢流动，'
    '结尾出现品牌名「NaN」，节奏干净克制。';
const String kCaseHotapp =
    '做一个待办清单热应用：支持新增、勾选完成、删除、筛选，本地保存，名字用 todo-native-check。';

const String kHotappsDir = r'C:/Users/kelthas/Documents/NoNDesign/hotapps';
const String kReportPath = r'D:/workplace/nan/diag/full_acceptance.md';

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
      if (id == null) return;
      final p = c._pending.remove(id);
      if (p == null) return;
      if (m['error'] != null) {
        p.completeError(Exception(jsonEncode(m['error'])));
      } else {
        p.complete(m['result']);
      }
    });
    return c;
  }

  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    final id = '${_id++}';
    final c = Completer<dynamic>();
    _pending[id] = c;
    _ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(minutes: 3));
  }
}

class Session {
  Session(this.vm, this.isolateId, this.lib, this.lines);
  final VmClient vm;
  final String isolateId;
  final String lib;
  final List<String> lines;

  Future<String?> ev(String expr) async {
    final r = await vm.call('evaluate', {
      'isolateId': isolateId,
      'targetId': lib,
      'expression': expr,
      'disableBreakpoints': true,
    });
    return r is Map ? r['valueAsString']?.toString() : null;
  }

  void log(String line) {
    lines.add(line);
    stdout.writeln(line);
  }
}

Set<String> hotappNames() => Directory(kHotappsDir)
    .listSync()
    .whereType<Directory>()
    .map((e) => e.path.split(Platform.pathSeparator).last)
    .toSet();

Future<void> main(List<String> args) async {
  final uri = args.first;
  final steps = (args.length > 1 ? args[1] : 'design,proto,three,video,hotapp')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
  bool want(String step) => steps.contains(step) || steps.contains('all');

  final report = File(kReportPath);
  final lines = <String>[];
  void sink(String line) {
    lines.add(line);
    stdout.writeln(line);
  }

  Future<void> flush() => report.writeAsString(lines.join('\n'));

  final vm = await VmClient.connect(uri);
  final vmInfo = await vm.call('getVM');
  final isolates = vmInfo['isolates'] as List;
  final mainIso = isolates.firstWhere((i) => (i['name'] ?? '') == 'main',
      orElse: () => isolates.first);
  final isolateId = mainIso['id'] as String;
  final iso = await vm.call('getIsolate', {'isolateId': isolateId});
  String? lib;
  for (final l in (iso['libraries'] as List)) {
    if ((l['uri'] ?? '').toString().endsWith('core/store.dart')) {
      lib = l['id'];
      break;
    }
  }
  if (lib == null) {
    stdout.writeln('**失败：找不到 store.dart 库**');
    exit(2);
  }
  final s = Session(vm, isolateId, lib, lines);

  sink('# 验收 ${DateTime.now().toString().substring(0, 19)} steps=${steps.join(",")}');
  sink('- 设计：$kCaseDesign');
  sink('- 3D：$kCaseThree');
  sink('- 视频：$kCaseVideo');
  sink('- 热应用：$kCaseHotapp');
  sink('');

  await s.ev('AppStore.debugInstance?.debugForceIdle()');
  final ready = await s.ev('AppStore.debugInstance != null');
  sink('- debugInstance: $ready');
  if (ready != 'true') {
    await flush();
    exit(2);
  }

  Future<bool> waitVerdict(int maxSec) async {
    for (var i = 0; i < maxSec ~/ 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final v = await s.ev('AppStore.debugInstance!.debugRunVerdict');
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return false;
  }

  Future<bool> runModule(String mode, String instruction, int maxSec) async {
    await s.ev(
        "AppStore.debugInstance!.debugRunModule('$mode', ${jsonEncode(instruction)})");
    return waitVerdict(maxSec);
  }

  var designOk = false;
  var protoOk = false;
  var threeOk = false;
  var videoOk = false;
  var hotOk = false;

  if (want('design')) {
    sink('## 1) 设计模块');
    final t = DateTime.now();
    designOk = await runModule('design', kCaseDesign, 1500);
    final boards = await s.ev('AppStore.debugInstance!.render.artboards.length');
    final prd = await s.ev('AppStore.debugInstance!.docs.prd.length');
    final ui = await s.ev('AppStore.debugInstance!.docs.ui.length');
    sink('- 终态: ${designOk ? "✅" : "❌"}，用时 ${DateTime.now().difference(t).inSeconds}s');
    sink('- 画板 $boards / PRD $prd 字 / UI $ui 字');
    await flush();
  }

  if (want('proto')) {
    sink('## 2) 设计 → 热应用（由原型生成）');
    final t = DateTime.now();
    final before = hotappNames();
    await s.ev('AppStore.debugInstance!.generateHotAppFromPrototype()');
    var started = false;
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await s.ev('AppStore.debugInstance!.hotappFromPrototypeBusy') == 'true') {
        started = true;
        break;
      }
    }
    var finished = false;
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (started &&
          await s.ev('AppStore.debugInstance!.hotappFromPrototypeBusy') == 'false') {
        finished = true;
        break;
      }
    }
    final added = hotappNames().difference(before);
    protoOk = finished && added.isNotEmpty;
    sink('- 完成: ${protoOk ? "✅" : "❌"}，用时 ${DateTime.now().difference(t).inSeconds}s');
    sink('- 新增应用: ${added.isEmpty ? "（无）" : added.join(", ")}');
    await flush();
  }

  if (want('three')) {
    sink('## 3) 3D 模块');
    final t = DateTime.now();
    threeOk = await runModule('three', kCaseThree, 900);
    sink('- 终态: ${threeOk ? "✅" : "❌"}，用时 ${DateTime.now().difference(t).inSeconds}s');
    await flush();
  }

  if (want('video')) {
    sink('## 4) 视频模块');
    final t = DateTime.now();
    videoOk = await runModule('video', kCaseVideo, 900);
    sink('- 终态: ${videoOk ? "✅" : "❌"}，用时 ${DateTime.now().difference(t).inSeconds}s');
    await flush();
  }

  if (want('hotapp')) {
    sink('## 5) 热应用模块（原生）');
    final t = DateTime.now();
    hotOk = await runModule('hotapp', kCaseHotapp, 1500);
    sink('- 终态: ${hotOk ? "✅" : "❌"}，用时 ${DateTime.now().difference(t).inSeconds}s');
    sink('- 热应用库: ${(hotappNames().toList()..sort()).join(", ")}');
    await flush();
  }

  sink('');
  sink('## 汇总');
  sink('| 步骤 | 结果 |');
  sink('|---|---|');
  if (want('design')) sink('| 设计 | ${designOk ? "✅" : "❌"} |');
  if (want('proto')) sink('| 设计→热应用 | ${protoOk ? "✅" : "❌"} |');
  if (want('three')) sink('| 3D | ${threeOk ? "✅" : "❌"} |');
  if (want('video')) sink('| 视频 | ${videoOk ? "✅" : "❌"} |');
  if (want('hotapp')) sink('| 热应用（原生） | ${hotOk ? "✅" : "❌"} |');
  await flush();

  final ran = <bool>[
    if (want('design')) designOk,
    if (want('proto')) protoOk,
    if (want('three')) threeOk,
    if (want('video')) videoOk,
    if (want('hotapp')) hotOk,
  ];
  exit(ran.every((ok) => ok) ? 0 : 1);
}
