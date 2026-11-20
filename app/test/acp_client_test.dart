// 外部智能体（ACP）客户端锚点测试（批次 09）。
//
// 覆盖：
//  * 12 项目录（含 Pivot 置灰）与移动端硬拒绝（不 spawn）；
//  * PATH 强化：nvm 各 node 版本 bin 新版优先、常见目录、常见安装路径；
//  * **假 ACP agent 全链**（真实子进程 + newline JSON-RPC）：
//    spawn → initialize → newSession → prompt → permission → fs 回调 → close；
//  * 第二次 prompt 的事件带新的 run id（promptId），不串轮；
//  * 权限应答线格式 `{"outcome":{"outcome":…,"optionId":…}}`（夹具畸形即 exit 3）；
//  * 工作区隔离：越界读被 JSON-RPC 错误拒绝；工作区内读写正常；
//  * 进程中途死亡 → failed(acp_agent_exited)；默认无确认界面 → 拒绝。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/acp_client.dart';

/// 测试宿主：不跑登录 shell（避免 8s 的 zsh 探测），spawn 走真实 Process。
class _TestHost implements AcpHost {
  _TestHost({
    bool desktop = true,
    Map<String, String> extraEnvironment = const <String, String>{},
  })  : isDesktop = desktop,
        _environment = <String, String>{
          ...Platform.environment,
          ...extraEnvironment,
        };

  @override
  final bool isDesktop;

  final Map<String, String> _environment;
  int spawnCalls = 0;

  @override
  String get homeDirectory =>
      _environment['HOME'] ?? _environment['USERPROFILE'] ?? Directory.current.path;

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
    spawnCalls += 1;
    return Process.start(
      argv.first,
      argv.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  }
}

String? _findDart() {
  final env = Platform.environment;
  final candidates = <String>[
    if ((env['FLUTTER_ROOT'] ?? '').isNotEmpty)
      '${env['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart',
    '${env['HOME'] ?? ''}/.flutter_sdk/bin/cache/dart-sdk/bin/dart',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file.path;
  }
  for (final dir in (env['PATH'] ?? '').split(':')) {
    if (dir.trim().isEmpty) continue;
    final file = File('$dir/dart');
    if (file.existsSync()) return file.path;
  }
  return null;
}

String _fixturePath() =>
    '${Directory.current.path}/test/fixtures/fake_acp_agent.dart';

AcpCatalogEntry _fakeEntry(String dartPath) => AcpCatalogEntry(
      id: 'fake',
      name: 'Fake ACP',
      note: 'test fixture',
      candidates: <AcpLaunchCandidate>[
        AcpLaunchCandidate(<String>['dart'], <String>['{exe}', _fixturePath()]),
      ],
    );

void main() {
  group('catalog', () {
    test('12 项白名单，Pivot 置灰，id 唯一', () {
      expect(acpCatalog.length, 12);
      final ids = acpCatalog.map((e) => e.id).toList();
      expect(ids.toSet().length, 12, reason: 'id 必须唯一');
      expect(ids, containsAll(<String>[
        'qwen', 'pi', 'claude-code', 'codex', 'dsh', 'stepcode',
        'mcode', 'kimi', 'omp', 'gemini', 'pivot', 'solon',
      ]));
      final pivot = acpCatalog.firstWhere((e) => e.id == 'pivot');
      expect(pivot.grayed, isTrue);
    });

    test('候选形态：native / npx / 静态 argv 三类都在', () {
      final all = acpCatalog.expand((e) => e.candidates).toList();
      expect(all.any((c) => c.isNpx), isTrue);
      expect(all.any((c) => !c.isNpx && c.execs.isNotEmpty), isTrue);
      for (final entry in acpCatalog) {
        expect(entry.candidates, isNotEmpty, reason: '${entry.id} 必须有启动形态');
        for (final candidate in entry.candidates) {
          expect(candidate.argv, isNotEmpty);
        }
      }
    });
  });

  group('mobile rejection', () {
    test('非桌面宿主直接拒绝且不 spawn', () async {
      final host = _TestHost(desktop: false);
      final client = AcpClient(host: host, catalog: const <AcpCatalogEntry>[]);
      await expectLater(
        client.start(agentId: 'fake', workspace: Directory.systemTemp.path),
        throwsA(isA<AcpFailure>().having((e) => e.code, 'code', 'acp_desktop_only')),
      );
      expect(host.spawnCalls, 0);
      expect(acpFailureMessage('acp_desktop_only'), '外部智能体只在电脑上可用');
    });
  });

  group('PATH 强化', () {
    test('nvm 版本 bin 新版优先 + 常见目录 + 进程 PATH', () async {
      final root = Directory.systemTemp.createTempSync('acp-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final v18 = Directory('${root.path}/.nvm/versions/node/v18.0.0/bin')..createSync(recursive: true);
      final v20 = Directory('${root.path}/.nvm/versions/node/v20.1.0/bin')..createSync(recursive: true);
      File('${v18.path}/fake-cli').writeAsStringSync('#!/bin/sh\n');
      File('${v20.path}/fake-cli').writeAsStringSync('#!/bin/sh\n');
      // chmod 只有 POSIX 有；Windows 的 which() 不依赖可执行位，跳过即可。
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', '${v18.path}/fake-cli', '${v20.path}/fake-cli']);
      }

      final host = _TestHost();
      final resolver = AcpPathResolver(
        host: host,
        extraDirs: const <String>['/opt/homebrew/bin', '/usr/local/bin'],
      );
      // homeDirectory 指向临时 home：用环境覆盖更直接。
      final scopedHost = _TestHost(extraEnvironment: {'HOME': root.path});
      final scoped = AcpPathResolver(
        host: scopedHost,
        extraDirs: const <String>['/opt/homebrew/bin'],
      );
      final dirs = await scoped.scanDirs();
      // Windows 的目录扫描/夹具拼接会产生不同分隔符形态：只比较语义路径。
      String norm(String path) => path.replaceAll('\\', '/');
      expect(norm(dirs.first), norm(v20.path), reason: 'nvm 新版必须排在旧版前');
      expect(norm(dirs[1]), norm(v18.path));
      expect(norm((await scoped.which('fake-cli'))!), norm('${v20.path}/fake-cli'));
      // 无关解析器仍能工作（不依赖登录 shell）。
      expect(await resolver.scanDirs(), isNotEmpty);
    });
  });

  group('fake agent full chain', () {
    late String dartPath;
    late _TestHost host;
    late AcpClient client;
    late Directory workspace;

    setUp(() {
      dartPath = _findDart() ?? '';
      workspace = Directory.systemTemp.createTempSync('acp-ws-');
      File('${workspace.path}/inside.txt').writeAsStringSync('hello-acp\n');
      // 越界目标：工作区同级文件。
      File('${Directory(workspace.path).parent.path}/outside-secret.txt')
          .writeAsStringSync('secret');
      host = _TestHost(extraEnvironment: <String, String>{'HOME': workspace.path});
      final resolver = AcpPathResolver(
        host: host,
        extraDirs: <String>[File(dartPath).parent.path],
      );
      client = AcpClient(
        host: host,
        resolver: resolver,
        catalog: <AcpCatalogEntry>[_fakeEntry(dartPath)],
        onPermission: (request) async {
          expect(request.options, isNotEmpty);
          return AcpPermissionDecision.selected('allow-once');
        },
      );
    });

    tearDown(() async {
      await client.close();
      try {
        workspace.deleteSync(recursive: true);
      } catch (_) {}
      try {
        File('${Directory(workspace.path).parent.path}/outside-secret.txt')
            .deleteSync();
      } catch (_) {}
    });

    test('spawn → initialize → newSession → prompt → permission → fs → close；两轮 run id 不串', () async {
      if (dartPath.isEmpty) {
        markTestSkipped('找不到 dart 可执行文件，跳过子进程链路');
        return;
      }
      final started = await client.start(agentId: 'fake', workspace: workspace.path);
      expect(started['ok'], isTrue);
      expect(started['sessionId'], 'fake-session');
      expect(host.spawnCalls, 1);

      final first = await client.prompt('第一条').toList();
      final firstText = first
          .where((e) => e['type'] == 'assistant_delta')
          .map((e) => (e['text'] ?? '').toString())
          .join();
      expect(firstText, contains('第 1 轮开始'));
      expect(firstText, contains('权限:selected:allow-once'));
      expect(firstText, contains('工作区内:hello-acp'));
      expect(firstText, contains('越界:blocked'));
      expect(firstText, contains('写入:ok'));
      expect(first.any((e) => e['type'] == 'tool_start'), isTrue);
      expect(first.any((e) => e['type'] == 'tool_end' && e['ok'] == true), isTrue);
      expect(first.where((e) => e['type'] == 'done').single['stopReason'], 'end_turn');
      expect(first.every((e) => e['promptId'] == 1), isTrue,
          reason: '第一轮事件必须全部带 promptId=1');
      // 工作区内写入真的落盘。
      expect(File('${workspace.path}/note.txt').readAsStringSync(), 'from agent');

      final second = await client.prompt('第二条').toList();
      final secondText = second
          .where((e) => e['type'] == 'assistant_delta')
          .map((e) => (e['text'] ?? '').toString())
          .join();
      expect(secondText, contains('第 2 轮开始'));
      expect(second.every((e) => e['promptId'] == 2), isTrue,
          reason: '第二轮事件必须带新的 run id（promptId=2）');
      expect(second.any((e) => e['promptId'] == 1), isFalse,
          reason: '第一轮的事件不得混入第二轮');

      await client.close();
      expect(client.isRunning, isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('并发 prompt → 第二轮显式 busy（不串事件汇）', () async {
      if (dartPath.isEmpty) {
        markTestSkipped('找不到 dart 可执行文件，跳过子进程链路');
        return;
      }
      await client.start(agentId: 'fake', workspace: workspace.path);
      final first = client.prompt('第一轮');
      final busy = await client.prompt('第二轮').toList();
      expect(busy.single['type'], 'failed');
      expect(busy.single['error'], 'acp_prompt_busy');
      expect(busy.single['message'], acpFailureMessage('acp_prompt_busy'));
      final events = await first.toList();
      expect(events.where((e) => e['type'] == 'done'), isNotEmpty);
      expect(events.every((e) => e['promptId'] == 1), isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('没有确认界面 → 默认拒绝（cancelled）并留过程提示', () async {
      if (dartPath.isEmpty) {
        markTestSkipped('找不到 dart 可执行文件，跳过子进程链路');
        return;
      }
      final notes = <String>[];
      final denying = AcpClient(
        host: host,
        resolver: AcpPathResolver(host: host, extraDirs: <String>[File(dartPath).parent.path]),
        catalog: <AcpCatalogEntry>[_fakeEntry(dartPath)],
        onNote: (label, detail) => notes.add('$label:$detail'),
      );
      addTearDown(denying.close);
      await denying.start(agentId: 'fake', workspace: workspace.path);
      final events = await denying.prompt('需要确认').toList();
      final text = events
          .where((e) => e['type'] == 'assistant_delta')
          .map((e) => (e['text'] ?? '').toString())
          .join();
      expect(text, contains('权限:cancelled:'));
      expect(notes.any((n) => n.startsWith('权限未确认')), isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('agent exit', () {
    test('prompt 中途进程死亡 → failed(acp_agent_exited)', () async {
      final dartPath = _findDart();
      if (dartPath == null || dartPath.isEmpty) {
        markTestSkipped('找不到 dart 可执行文件，跳过子进程链路');
        return;
      }
      final workspace = Directory.systemTemp.createTempSync('acp-exit-');
      addTearDown(() {
        try {
          workspace.deleteSync(recursive: true);
        } catch (_) {}
      });
      final host = _TestHost(extraEnvironment: <String, String>{
        'HOME': workspace.path,
        'FAKE_ACP_EXIT_ON_PROMPT': '1',
      });
      final client = AcpClient(
        host: host,
        resolver: AcpPathResolver(host: host, extraDirs: <String>[File(dartPath).parent.path]),
        catalog: <AcpCatalogEntry>[_fakeEntry(dartPath)],
      );
      addTearDown(client.close);
      await client.start(agentId: 'fake', workspace: workspace.path);
      final events = await client.prompt('触发退出').toList();
      final failed = events.where((e) => e['type'] == 'failed').toList();
      expect(failed, isNotEmpty);
      expect(failed.first['error'], 'acp_agent_exited');
      expect(failed.first['message'], acpFailureMessage('acp_agent_exited'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
