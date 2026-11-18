// 发布包桌面状态检查（批次 15）。
//
// 用法（在仓库根）：
//   dart run scripts/wf/check_desktop_release.dart \
//     --app app/build/macos/Build/Products/Release/NoNDesign.app --home /tmp/nd-home
//
// 它回答三个问题：
//
//  1. **发布包里没有 Python 运行时的残留**：无 `.py/.pyc`、无 `server/`、
//     无 `.venv/`、无 `server/requirements.txt`。
//  2. **默认启动不监听、不拉起外部进程**：以干净的 HOME 启动 Release app，
//     等待启动完成后断言——进程及其全部子孙进程里没有 python / server/main.py
//     / .venv；没有 TCP LISTEN 或 UDP 绑定；HOME 下没有 `~/.nondesign/server.json`。
//  3. **「连接桌面」宿主仍是临时端口 + token**（静态契约）：宿主默认 loopback、
//     `port = 0`、token 必填。动态「开启后只有临时端口 + token」需要设置/壳层
//     提供用户开关；当前构建没有这个开关时，本脚本如实报告
//     `host_toggle_wiring_missing`，不伪造通过（--expect-host 会把这一项变成失败）。
//
// 退出码：0 = 必检项全过；1 = 有必检项失败；2 = 环境/参数问题，检查未执行。
//
// 注意：ad-hoc 签名的 bundle 在部分 macOS 上首次启动会弹 TCC 文稿权限框；
// 本脚本用临时 HOME、不写入用户目录，只验证「无 Python / 无监听 / 无端口文件」，
// 不替代正式分发签名验收。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String _defaultApp =
    'app/build/macos/Build/Products/Release/NoNDesign.app';

/// One check's outcome.
class CheckResult {
  CheckResult(this.name, this.ok, {this.detail = '', this.mandatory = true});

  final String name;
  final bool ok;
  final String detail;
  final bool mandatory;

  Map<String, Object?> toJson() => {
        'check': name,
        'ok': ok,
        'mandatory': mandatory,
        if (detail.isNotEmpty) 'detail': detail,
      };
}

/// Parsed command line.
class Options {
  Options({
    required this.appPath,
    required this.homePath,
    required this.wait,
    required this.bundleOnly,
    required this.json,
    required this.strictHost,
    required this.keepRunning,
  });

  final String appPath;
  final String homePath;
  final Duration wait;
  final bool bundleOnly;
  final bool json;

  /// When true (default), a missing in-app switch for the desktop host is a
  /// failure: the release cannot claim "connect desktop" is usable.
  final bool strictHost;

  final bool keepRunning;

  static Options parse(List<String> args) {
    String? app;
    String? home;
    var wait = const Duration(seconds: 15);
    var bundleOnly = false;
    var json = false;
    var strictHost = true;
    var keep = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String next() {
        if (i + 1 >= args.length) {
          throw FormatException('$arg 缺少参数');
        }
        return args[++i];
      }

      switch (arg) {
        case '--app':
          app = next();
        case '--home':
          home = next();
        case '--wait':
          wait = Duration(seconds: int.parse(next()));
        case '--bundle-only':
          bundleOnly = true;
        case '--json':
          json = true;
        case '--allow-unwired-host':
          strictHost = false;
        case '--keep-running':
          keep = true;
        case '--help' || '-h':
          stdout.writeln('''
用法: dart run scripts/wf/check_desktop_release.dart [选项]

  --app <NoNDesign.app>     发布包路径（默认 $_defaultApp）
  --home <dir>              启动时使用的 HOME（默认临时目录）
  --wait <seconds>          启动后等待时间（默认 15）
  --bundle-only             只做 bundle 检查，不启动
  --allow-unwired-host      把「连接桌面没有用户开关」降级为警告（仅开发期）
  --keep-running            检查完不结束进程（人工观察用）
  --json                    JSON 输出

默认把宿主开关缺失视为失败：发布验收不能声称「连接桌面」可用而实际没有入口。
''');
          exit(0);
        default:
          throw FormatException('未知参数: $arg');
      }
    }
    return Options(
      appPath: app ?? _defaultApp,
      homePath: home ?? '',
      wait: wait,
      bundleOnly: bundleOnly,
      json: json,
      strictHost: strictHost,
      keepRunning: keep,
    );
  }
}

Future<void> main(List<String> args) async {
  Options options;
  try {
    options = Options.parse(args);
  } on FormatException catch (error) {
    stderr.writeln('check_desktop_release: ${error.message}');
    exit(2);
  }

  final checks = <CheckResult>[];
  final appDir = Directory(options.appPath).absolute;
  if (!appDir.existsSync()) {
    stderr.writeln('check_desktop_release: 找不到发布包 ${appDir.path}');
    exit(2);
  }

  checks.addAll(_auditBundle(appDir));

  if (!options.bundleOnly) {
    final createdHome = options.homePath.isEmpty;
    final home = createdHome
        ? Directory.systemTemp.createTempSync('nondesign-release-home_')
        : Directory(options.homePath)..createSync(recursive: true);
    checks.addAll(await _auditRuntime(appDir, home, options));
    if (createdHome && !options.keepRunning) {
      try {
        home.deleteSync(recursive: true);
      } catch (_) {
        // 临时 HOME 清理失败不影响结论。
      }
    }
  }

  checks.addAll(_staticHostContract());

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'app': appDir.path,
      'checks': checks.map((c) => c.toJson()).toList(),
      'ok': checks.where((c) => c.mandatory).every((c) => c.ok),
    }));
  } else {
    stdout.writeln('发布包：${appDir.path}');
    for (final check in checks) {
      final mark = check.ok ? 'PASS' : (check.mandatory ? 'FAIL' : 'WARN');
      final suffix = check.detail.isEmpty ? '' : ' — ${check.detail}';
      stdout.writeln('[$mark] ${check.name}$suffix');
    }
    final failed = checks.where((c) => c.mandatory && !c.ok).toList();
    stdout.writeln('');
    stdout.writeln(failed.isEmpty
        ? '全部必检项通过。'
        : '${failed.length} 项必检失败：${failed.map((c) => c.name).join(', ')}');
  }

  final failed = checks.where((c) => c.mandatory && !c.ok);
  exit(failed.isEmpty ? 0 : 1);
}

// ---------------------------------------------------------------------------
// 1. Bundle 内容
// ---------------------------------------------------------------------------

List<CheckResult> _auditBundle(Directory appDir) {
  final pyFiles = <String>[];
  final serverDirs = <String>[];
  final venvDirs = <String>[];
  var files = 0;
  for (final entity in appDir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    files++;
    final path = entity.path;
    final lower = path.toLowerCase();
    final name = path.split(Platform.pathSeparator).last.toLowerCase();
    if (lower.endsWith('.py') || lower.endsWith('.pyc') || lower.endsWith('.pyo')) {
      pyFiles.add(path);
    }
    final segments = lower.split(Platform.pathSeparator);
    if (segments.contains('server')) serverDirs.add(path);
    if (segments.contains('.venv') || segments.contains('venv')) venvDirs.add(path);
    if (name == 'requirements.txt' && segments.contains('server')) {
      serverDirs.add(path);
    }
  }
  final clean = pyFiles.isEmpty && serverDirs.isEmpty && venvDirs.isEmpty;
  return [
    CheckResult(
      'bundle_has_no_python_runtime',
      clean,
      detail: clean
          ? '扫描 $files 个文件，无 .py/.pyc、无 server/、无 .venv/'
          : [
              if (pyFiles.isNotEmpty) 'Python 文件 ${pyFiles.length} 个（${pyFiles.take(3).join(', ')}）',
              if (serverDirs.isNotEmpty) 'server 目录 ${serverDirs.length} 处',
              if (venvDirs.isNotEmpty) '.venv 目录 ${venvDirs.length} 处',
            ].join('；'),
    ),
  ];
}

// ---------------------------------------------------------------------------
// 2. 启动后的运行时状态
// ---------------------------------------------------------------------------

Future<List<CheckResult>> _auditRuntime(
  Directory appDir,
  Directory home,
  Options options,
) async {
  final results = <CheckResult>[];
  final executable = await _bundleExecutable(appDir);
  if (executable == null) {
    return [
      CheckResult('app_launch', false, detail: '找不到 Contents/MacOS 下的可执行文件'),
    ];
  }

  final env = <String, String>{
    ...Platform.environment,
    'HOME': home.path,
  }..removeWhere((key, _) => key.startsWith('NONDESIGN_'));

  final Process process;
  try {
    process = await Process.start(
      executable,
      const <String>[],
      environment: env,
      workingDirectory: File(executable).parent.path,
    );
  } catch (error) {
    return [
      CheckResult('app_launch', false, detail: '$error'),
    ];
  }
  final output = StringBuffer();
  final errOutput = StringBuffer();
  final stdoutSub = process.stdout.transform(utf8.decoder).listen((chunk) {
    if (output.length < 8192) output.write(chunk);
  });
  final stderrSub = process.stderr.transform(utf8.decoder).listen((chunk) {
    if (errOutput.length < 8192) errOutput.write(chunk);
  });

  final pid = process.pid;
  var exited = false;
  final exitWatch = process.exitCode.then((code) {
    exited = true;
    return code;
  });

  try {
    // 启动窗口：Flutter 首帧 + 设置/本地引擎启动。默认 15s 足够在 CI 机器上
    // 完成；--wait 可调。
    await Future.any([
      Future<void>.delayed(options.wait),
      exitWatch.then((_) => null),
    ]);

    if (exited) {
      final code = await exitWatch;
      results.add(CheckResult(
        'app_launch',
        false,
        detail: '进程启动后退出（code=$code）。stdout=${_brief(output)} stderr=${_brief(errOutput)}',
      ));
      return results;
    }
    results.add(CheckResult('app_launch', true, detail: 'pid=$pid'));

    // 2a. 监听面。
    final listeners = await _listeningPorts(pid);
    results.add(CheckResult(
      'no_listening_ports_by_default',
      listeners.isEmpty,
      detail: listeners.isEmpty ? 'TCP/UDP 无监听' : '发现监听：${listeners.join(', ')}',
    ));

    // 2b. 子孙进程。
    final descendants = await _descendants(pid);
    final offenders = descendants
        .where((entry) => _looksLikePython(entry.command))
        .map((entry) => '${entry.pid}: ${entry.command}')
        .toList();
    results.add(CheckResult(
      'no_python_child_processes',
      offenders.isEmpty,
      detail: offenders.isEmpty
          ? '检查 ${descendants.length} 个子孙进程，无 python / server/main.py / .venv'
          : offenders.join(' | '),
    ));

    // 2c. 端口文件。
    final serverJson = File('${home.path}/.nondesign/server.json');
    results.add(CheckResult(
      'no_server_json',
      !serverJson.existsSync(),
      detail: serverJson.existsSync() ? serverJson.path : '${home.path}/.nondesign/server.json 不存在',
    ));

    // 2d. 固定端口不出现（进程命令行 + 端口文件都已覆盖；这里补一条 HOME 扫描）。
    final strayPortFiles = <String>[];
    final nondesign = Directory('${home.path}/.nondesign');
    if (nondesign.existsSync()) {
      for (final entity in nondesign.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name == 'server.json' || name == 'port' || name == 'port.txt') {
          strayPortFiles.add(entity.path);
        }
      }
    }
    results.add(CheckResult(
      'no_fixed_port_files',
      strayPortFiles.isEmpty,
      detail: strayPortFiles.isEmpty ? '无 server.json / port 文件' : strayPortFiles.join(', '),
    ));

    // 2e. 连接桌面宿主的动态开关：当前构建没有用户入口。
    final toggle = _hostToggleWiring();
    results.add(CheckResult(
      'host_toggle_available',
      toggle.found,
      mandatory: options.strictHost,
      detail: toggle.found
          ? '设置/壳层引用 DesktopRpcHost：${toggle.evidence}'
          : '当前构建没有启动「连接桌面」宿主的界面入口（宿主实现已在 '
              'app/lib/core/remote/desktop_rpc_host.dart，设置/壳层接线缺失）'
              '——动态验证「开启后只有临时端口 + token」不可执行',
    ));
  } finally {
    await stdoutSub.cancel();
    await stderrSub.cancel();
    if (!options.keepRunning && !exited) {
      process.kill(ProcessSignal.sigterm);
      await exitWatch.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }
  return results;
}

Future<String?> _bundleExecutable(Directory appDir) async {
  final infoPlist = File('${appDir.path}/Contents/Info.plist');
  var name = 'NoNDesign';
  if (infoPlist.existsSync()) {
    try {
      final result = await Process.run(
        'plutil',
        ['-extract', 'CFBundleExecutable', 'raw', infoPlist.path],
      );
      if (result.exitCode == 0) {
        final parsed = '${result.stdout}'.trim();
        if (parsed.isNotEmpty) name = parsed;
      }
    } catch (_) {
      // plutil 不可用时回落到默认名。
    }
  }
  final executable = File('${appDir.path}/Contents/MacOS/$name');
  return executable.existsSync() ? executable.absolute.path : null;
}

Future<List<String>> _listeningPorts(int pid) async {
  final found = <String>[];
  for (final args in <List<String>>[
    ['-nP', '-a', '-p', '$pid', '-iTCP', '-sTCP:LISTEN'],
    ['-nP', '-a', '-p', '$pid', '-iUDP'],
  ]) {
    try {
      final result = await Process.run('lsof', args);
      final text = '${result.stdout}'.trim();
      if (text.isEmpty) continue;
      for (final line in const LineSplitter().convert(text)) {
        if (line.startsWith('COMMAND')) continue;
        final columns = line.split(RegExp(r'\s+'));
        if (columns.length >= 9) {
          found.add('${columns[0]} ${columns[7]} ${columns.sublist(8).join(' ')}');
        } else {
          found.add(line);
        }
      }
    } on ProcessException catch (error) {
      found.add('lsof 不可用：$error');
    }
  }
  return found;
}

class _ProcEntry {
  _ProcEntry(this.pid, this.ppid, this.command);

  final int pid;
  final int ppid;
  final String command;
}

Future<List<_ProcEntry>> _descendants(int rootPid) async {
  final ProcessResult result;
  try {
    result = await Process.run('ps', ['-axo', 'pid=,ppid=,command=']);
  } on ProcessException {
    return const [];
  }
  if (result.exitCode != 0) return const [];
  final byPid = <int, _ProcEntry>{};
  for (final line in const LineSplitter().convert('${result.stdout}')) {
    final match = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
    if (match == null) continue;
    final pid = int.parse(match.group(1)!);
    byPid[pid] = _ProcEntry(pid, int.parse(match.group(2)!), match.group(3)!);
  }
  final out = <_ProcEntry>[];
  final queue = <int>[rootPid];
  final seen = <int>{rootPid};
  while (queue.isNotEmpty) {
    final parent = queue.removeAt(0);
    for (final entry in byPid.values) {
      if (entry.ppid != parent || seen.contains(entry.pid)) continue;
      seen.add(entry.pid);
      out.add(entry);
      queue.add(entry.pid);
    }
  }
  return out;
}

bool _looksLikePython(String command) {
  final lower = command.toLowerCase();
  if (lower.contains('server/main.py')) return true;
  if (lower.contains('.venv')) return true;
  return RegExp(r'(^|[\s/\\])python[0-9.]*(\s|$)').hasMatch(lower);
}

String _brief(StringBuffer buffer) {
  final text = buffer.toString().replaceAll('\n', ' ').trim();
  return text.length <= 300 ? text : '${text.substring(0, 300)}…';
}

// ---------------------------------------------------------------------------
// 3. 「连接桌面」宿主契约（静态，当前构建动态不可达时仍能证明边界）
// ---------------------------------------------------------------------------

List<CheckResult> _staticHostContract() {
  final root = _repoRoot();
  final host = File('${root.path}/app/lib/core/remote/desktop_rpc_host.dart');
  final auth = File('${root.path}/app/lib/core/remote/rpc_auth.dart');
  if (!host.existsSync() || !auth.existsSync()) {
    return [
      CheckResult('host_contract_source', false, detail: '找不到宿主源码（非仓库内运行？）'),
    ];
  }
  final hostText = host.readAsStringSync();
  final authText = auth.readAsStringSync();
  final failures = <String>[];
  if (!hostText.contains('this.port = 0')) {
    failures.add('默认端口不是 0（系统分配临时端口）');
  }
  if (!hostText.contains('this.allowLan = false')) {
    failures.add('默认不是 loopback（allowLan 默认值改变）');
  }
  if (!authText.toLowerCase().contains('authorization')) {
    failures.add('token 鉴权头缺失');
  }
  if (!authText.contains('Random.secure')) {
    failures.add('token 不是安全随机');
  }
  return [
    CheckResult(
      'host_contract_static',
      failures.isEmpty,
      detail: failures.isEmpty
          ? '默认 loopback、port=0、Bearer token 必填（源码契约）'
          : failures.join('；'),
    ),
  ];
}

/// 设置/壳层是否真的引用了宿主（动态开启面的证据）。
({bool found, String evidence}) _hostToggleWiring() {
  final root = _repoRoot();
  final lib = Directory('${root.path}/app/lib');
  if (!lib.existsSync()) return (found: false, evidence: '');
  final hits = <String>[];
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // 宿主自身/协议/方法表不算「接线」。
    if (entity.path.contains('/core/remote/')) continue;
    final text = entity.readAsStringSync();
    if (text.contains('DesktopRpcHost') || text.contains('RpcHostStatus')) {
      hits.add(entity.path.substring(lib.path.length + 1));
    }
  }
  return (found: hits.isNotEmpty, evidence: hits.join(', '));
}

Directory _repoRoot() {
  var dir = File(Platform.script.toFilePath()).absolute.parent;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/app/lib').existsSync() &&
        Directory('${dir.path}/engine').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}
