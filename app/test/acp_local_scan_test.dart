// 本机外部智能体直扫（2026-11-19）：无桌面连接时 acpAgents 在进程内跑
// 同一 AcpPathResolver 探测器——独立安装也能列出本地已装的 CLI，不再返回
// 空列表（用户实测缺陷：外部智能体页扫不到本地已装智能体）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/acp_client.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/remote/rpc_methods.dart';

class _FakeHost implements AcpHost {
  _FakeHost({required this.root})
    : isDesktop = true,
      _environment = <String, String>{'HOME': root.path, 'PATH': ''};

  final Directory root;

  @override
  final bool isDesktop;

  final Map<String, String> _environment;

  @override
  String get homeDirectory => root.path;

  @override
  @override
  Map<String, String> get environment => Map<String, String>.from(_environment);

  @override
  Future<String> loginPath() async => '';

  @override
  Future<Process> spawn(
    List<String> argv, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) {
    throw UnimplementedError('detect 不 spawn');
  }
}

/// 唯一 catalog：codex（可执行形态 + npx 形态各一），注入后探测面确定。
final List<AcpCatalogEntry> _catalog = <AcpCatalogEntry>[
  const AcpCatalogEntry(
    id: 'nan-probe',
    name: 'NaN Probe CLI',
    note: 'test',
    candidates: [
      AcpLaunchCandidate(['nan-probe-cli'], ['{exe}']),
    ],
  ),
];

void main() {
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('nan_local_acp_');
    // 装一个「本机 CLI」：$HOME/.local/bin/codex-acp（带可执行位）。
    final bin = Directory('${root.path}/.local/bin')..createSync(recursive: true);
    final exe = File('${bin.path}/nan-probe-cli')..writeAsStringSync('#!/bin/sh\n');
    // Windows 无可执行位概念——测试在 macOS/Linux 跑，走 stat.mode 分支。
    if (!Platform.isWindows) {
      // chmod +x：resolver 走 stat.mode 可执行位检查。
      Process.runSync('chmod', <String>['+x', exe.path]);
    }
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('无桌面连接：本机直扫列出本地已装 CLI（不再是空列表）', () async {
    final api = NoNDesignApi.runtime(
      localAcp: SystemRpcAcpRuntime(
        host: _FakeHost(root: root),
        catalog: _catalog,
      ),
    );
    final agents = await api.acpAgents(probe: true);
    expect(agents, isNotEmpty, reason: '本地已装 codex-acp，必须被扫出来');
    // detect() 走全量 acpCatalog（真机上可能还装着别的 CLI）——按 id 断言。
    final probe = agents.where((a) => a.id == 'nan-probe').toList();
    expect(probe, hasLength(1));
    expect(probe.single.installed, isTrue);
    expect(probe.single.executable, contains('nan-probe-cli'));
  });

  test('本地未装：返回空列表（诚实），不报错', () async {
    final emptyRoot = Directory.systemTemp.createTempSync('nan_local_acp_empty_');
    addTearDown(() => emptyRoot.deleteSync(recursive: true));
    final api = NoNDesignApi.runtime(
      localAcp: SystemRpcAcpRuntime(
        host: _FakeHost(root: emptyRoot),
        catalog: _catalog,
      ),
    );
    final agents = await api.acpAgents(probe: true);
    // 空根 + 私有探针名（全机必不存在）：未装 = installed 如实为 false。
    expect(
      agents.where((a) => a.id == 'nan-probe' && a.installed),
      isEmpty,
    );
    expect(agents, isA<List<dynamic>>());
  });
}
