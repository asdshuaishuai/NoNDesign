/// 外部智能体（ACP）客户端——进程内直连，不经任何服务。
///
/// 线格式：**newline-delimited JSON-RPC 2.0**（一行一条消息；迁移前的
/// `server/acp_bridge.py` 与 NoNDesign step 适配层同形态）。客户端拉起本机
/// 已安装的 ACP 智能体 CLI，依次完成 `initialize` → `session/new` →
/// `session/prompt`，把 `session/update` 通知翻译成与内置循环同族的事件
/// （assistant_delta / thinking_delta / tool_start / tool_end / note / done /
/// failed），每个事件带本轮 `promptId`（即 run id）。
///
/// 边界（硬纪律）：
///  * **桌面独占**：手机/平板不能 spawn 任意进程——[AcpClient.isSupportedHost]
///    为 false 时 [AcpClient.start] 直接抛 `acp_desktop_only`，界面据此给出
///    人话提示，绝不假装可用；
///  * **12 项目录 + PATH 强化**：nvm 各 node 版本 bin（新版优先）→ 登录 shell
///    的 PATH → 常见安装目录 → 进程 PATH；`npx` 形态同样在探测范围内；
///    [AcpPathResolver.detect] 看可启动形态，[probeAcpAgent] 真跑一次握手；
///  * **工作区隔离**：agent 的 `fs/read_text_file` / `fs/write_text_file`
///    只能落在工作区内（符号链接真实路径也校验），越界返回 JSON-RPC 错误
///    （`-32001`），不写盘、不读盘；
///  * **权限全量确认**：agent 的 `session/request_permission` 交给
///    [AcpPermissionHandler]；没有处理者时**默认拒绝**（安全缺省），应答线格式
///    是 `{"outcome":{"outcome":"selected","optionId":…}}`；
///  * 进程退出 → 在飞的 prompt 收到 `failed(acp_agent_exited)`，会话句柄失效。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ============================================================
// 失败与文案
// ============================================================

/// 外部智能体失败（内部代号只进日志与技术详情）。
class AcpFailure implements Exception {
  const AcpFailure(this.code, [this.detail = '']);

  /// 机器码（`acp_desktop_only` / `acp_agent_not_found` / …）。
  final String code;

  /// 原始诊断，永不上屏。
  final String detail;

  @override
  String toString() => detail.isEmpty ? code : '$code: $detail';
}

/// 失败码 → 用户可见的一句话（术语表 §4：不出现实现名与裸错误码）。
String acpFailureMessage(String? code) {
  switch (code) {
    case 'acp_desktop_only':
      return '外部智能体只在电脑上可用';
    case 'acp_agent_not_found':
      return '没有找到这个外部智能体，先在电脑上安装它';
    case 'acp_agent_grayed':
      return '这个智能体还没有接入，换一个试试';
    case 'acp_agent_not_startable':
    case 'acp_agent_exited':
      return '外部智能体没能启动，请稍后重试';
    case 'acp_agent_timeout':
      return '外部智能体没有响应，请稍后重试';
    case 'acp_session_not_started':
      return '外部智能体会话还没有准备好，请重试';
    case 'acp_prompt_busy':
      return '上一轮还没有结束，等它完成再发送';
    case 'acp_permission_denied':
      return '这次操作需要你的确认，已先停住';
    case 'acp_cancelled':
      return '已取消';
    default:
      return '外部智能体这次没有完成，请重试';
  }
}

// ============================================================
// 目录（12 项，逐字对齐 server/acp_bridge.py 的最终白名单）
// ============================================================

/// 一个可启动形态：`execs` 命中即用 `argv`（`{exe}` 替换成命中路径）。
class AcpLaunchCandidate {
  const AcpLaunchCandidate(this.execs, this.argv);

  final List<String> execs;
  final List<String> argv;

  bool get isNpx => argv.isNotEmpty && argv.first == 'npx';
  bool get isStatic => execs.isEmpty;
}

/// 目录项。
class AcpCatalogEntry {
  const AcpCatalogEntry({
    required this.id,
    required this.name,
    required this.note,
    required this.candidates,
    this.grayed = false,
  });

  final String id;
  final String name;
  final String note;
  final List<AcpLaunchCandidate> candidates;

  /// 占位项（Pivot 尚未接入）。
  final bool grayed;
}

/// 最终白名单（用户定案 2026-11-15）：
/// qwen / pi / claude / codex / dsh / stepcode / mcode / kimi / omp / gemini /
/// pivot(置灰) / solon。
///
/// StepCode 的「自研适配层」在迁移后不再有 Python 脚本：只保留 `step acp`
/// 本体形态；CLI 在场但无 ACP 子命令时如实标注不可启动。
const List<AcpCatalogEntry> acpCatalog = <AcpCatalogEntry>[
  AcpCatalogEntry(
    id: 'qwen',
    name: 'Qwen Code',
    note: 'gemini-cli 分支，--experimental-acp 旗标',
    candidates: [
      AcpLaunchCandidate(['qwen'], ['{exe}', '--experimental-acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'pi',
    name: 'Pi',
    note: 'pi 系 ACP 入口为 <exe> acp 子命令（oh-my-pi 实证同形态）',
    candidates: [
      AcpLaunchCandidate(['pi'], ['{exe}', 'acp']),
      AcpLaunchCandidate(['pi-acp'], ['{exe}']),
      AcpLaunchCandidate(['npx'], ['npx', '-y', 'pi-acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'claude-code',
    name: 'Claude Code',
    note: '经 Zed 官方适配器（本机无适配器二进制时经 npx 拉取）',
    candidates: [
      AcpLaunchCandidate(['claude-code-acp', 'claude-agent-acp'], ['{exe}']),
      AcpLaunchCandidate(['npx'], ['npx', '-y', '@zed-industries/claude-code-acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'codex',
    name: 'Codex CLI',
    note: '经 Zed 官方适配器 codex-acp',
    candidates: [
      AcpLaunchCandidate(['codex-acp'], ['{exe}']),
      AcpLaunchCandidate(['npx'], ['npx', '-y', '@zed-industries/codex-acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'dsh',
    name: 'DSH',
    note: 'DeepSeek CLI；acp 子命令形态待协议探测裁决',
    candidates: [
      AcpLaunchCandidate(['dsh'], ['{exe}', 'acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'stepcode',
    name: 'StepCode',
    note: 'step acp 子命令；自研文本流适配层已随服务进程退役',
    candidates: [
      AcpLaunchCandidate(['step', 'stepcode'], ['{exe}', 'acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'mcode',
    name: 'MiniMax Code',
    note: 'MiniMax Code 官方 acp 子命令；new_session 要求先 mcode login',
    candidates: [
      AcpLaunchCandidate(['mcode', 'minimax-code', 'minimax'], ['{exe}', 'acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'kimi',
    name: 'Kimi Code',
    note: 'Kimi CLI 的 acp 子命令',
    candidates: [
      AcpLaunchCandidate(['kimi'], ['{exe}', 'acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'omp',
    name: 'OMP',
    note: 'oh-my-pi（pi 系发行版，实测 native ACP）',
    candidates: [
      AcpLaunchCandidate(['omp'], ['{exe}', 'acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'gemini',
    name: 'Gemini CLI',
    note: 'Google 官方 CLI，--experimental-acp 旗标',
    candidates: [
      AcpLaunchCandidate(['gemini'], ['{exe}', '--experimental-acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'pivot',
    name: 'Pivot',
    note: '我们自己的智能体 · 即将接入',
    grayed: true,
    candidates: [
      AcpLaunchCandidate(['pivot'], ['{exe}', 'acp']),
    ],
  ),
  AcpCatalogEntry(
    id: 'solon',
    name: 'Solon Code',
    note: 'Java 版（opensolon/soloncodecli，需 Java 17+）：ACP 经配置启用'
        '（solon.code.cli: acpEnabled + acpTransport: stdio），无独立子命令',
    candidates: [
      AcpLaunchCandidate(['solon', 'solon-code', 'soloncodecli'], ['{exe}', 'acp']),
    ],
  ),
];

/// 探测结果（给设置面板的目录行）。
class AcpAgentAvailability {
  const AcpAgentAvailability({
    required this.id,
    required this.name,
    required this.installed,
    required this.selectable,
    required this.note,
    this.executable,
    this.command = const <String>[],
    this.via = '',
    this.grayed = false,
  });

  final String id;
  final String name;
  final bool installed;
  final bool selectable;
  final String note;
  final String? executable;
  final List<String> command;
  final String via;
  final bool grayed;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'installed': installed,
        'selectable': selectable,
        'executable': executable,
        'command': command,
        'via': via,
        'note': note,
        'grayed': grayed,
      };
}

// ============================================================
// 宿主与 PATH 强化
// ============================================================

/// 进程/路径宿主。测试注入假实现；生产用 [SystemAcpHost]。
abstract class AcpHost {
  /// 是否支持 spawn 任意进程（桌面三平台 true，手机/平板 false）。
  bool get isDesktop;

  /// 用户主目录（nvm 探测用）。
  String get homeDirectory;

  /// 进程环境（spawn 子进程时透传并强化 PATH）。
  Map<String, String> get environment;

  /// 登录 shell 的 PATH（`zsh -lc 'echo $PATH'`）；失败返回空串。
  Future<String> loginPath();

  /// 拉起子进程。
  Future<Process> spawn(
    List<String> argv, {
    required String workingDirectory,
    required Map<String, String> environment,
  });
}

/// 生产宿主。
class SystemAcpHost implements AcpHost {
  SystemAcpHost({Map<String, String>? environment})
      : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;
  String? _loginPathCache;

  @override
  bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  String get homeDirectory =>
      _environment['HOME'] ?? _environment['USERPROFILE'] ?? Directory.current.path;

  @override
  Map<String, String> get environment => Map<String, String>.from(_environment);

  @override
  Future<String> loginPath() async {
    final cached = _loginPathCache;
    if (cached != null) return cached;
    var value = '';
    if (!Platform.isWindows) {
      try {
        final result = await Process.run(
          '/bin/zsh',
          const ['-lc', 'echo \$PATH'],
          environment: environment,
          stdoutEncoding: utf8,
        ).timeout(const Duration(seconds: 8));
        if (result.exitCode == 0) value = (result.stdout as String).trim();
      } catch (_) {
        value = '';
      }
    }
    _loginPathCache = value;
    return value;
  }

  @override
  Future<Process> spawn(
    List<String> argv, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) =>
      Process.start(
        argv.first,
        argv.sublist(1),
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
}

/// PATH 强化解析（nvm 降序 → 登录 PATH → 常见目录 → 进程 PATH）。
class AcpPathResolver {
  AcpPathResolver({required this.host, List<String>? extraDirs})
      : _extraDirs = extraDirs ??
            const <String>[
              '.local/bin',
              '.stepcode/bin',
              'bin',
              '/opt/homebrew/bin',
              '/usr/local/bin',
              '/opt/homebrew/sbin',
              '/usr/local/sbin',
            ];

  final AcpHost host;
  final List<String> _extraDirs;
  List<String>? _cache;

  /// 探测目录序（去重）。
  Future<List<String>> scanDirs() async {
    final cached = _cache;
    if (cached != null) return cached;
    final dirs = <String>[];
    final nvmRoot = Directory('${host.homeDirectory}/.nvm/versions/node');
    if (nvmRoot.existsSync()) {
      final versions = nvmRoot
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final version in versions) {
        final bin = Directory('${version.path}/bin');
        if (bin.existsSync()) dirs.add(bin.path);
      }
    }
    final login = await host.loginPath();
    for (final chunk in login.split(Platform.isWindows ? ';' : ':')) {
      if (chunk.trim().isNotEmpty) dirs.add(chunk.trim());
    }
    for (final extra in _extraDirs) {
      if (extra.startsWith('/')) {
        dirs.add(extra);
      } else {
        dirs.add('${host.homeDirectory}/$extra');
      }
    }
    final envPath = host.environment['PATH'] ?? '';
    for (final chunk in envPath.split(Platform.isWindows ? ';' : ':')) {
      if (chunk.trim().isNotEmpty) dirs.add(chunk.trim());
    }
    final seen = <String>{};
    _cache = [
      for (final dir in dirs)
        if (seen.add(dir)) dir,
    ];
    return _cache!;
  }

  /// 在强化目录里找一个可执行文件。
  Future<String?> which(String name) async {
    final isWindows = Platform.isWindows;
    for (final dir in await scanDirs()) {
      final candidate = File('$dir${Platform.pathSeparator}$name');
      if (!candidate.existsSync()) continue;
      if (isWindows) return candidate.path;
      // POSIX 可执行位。
      try {
        final stat = candidate.statSync();
        // mode & 0x49 = owner/group/other execute bits.
        if ((stat.mode & 0x49) != 0) return candidate.path;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// 子进程环境：PATH 前置强化目录（适配器内部再 spawn `pi`/`node` 也能解析）。
  Future<Map<String, String>> childEnvironment() async {
    final env = host.environment;
    env['PATH'] = (await scanDirs()).join(Platform.isWindows ? ';' : ':');
    return env;
  }

  /// 解析目录项的可启动形态。
  Future<AcpLaunchCandidate?> resolveCandidate(AcpCatalogEntry entry) async {
    for (final candidate in entry.candidates) {
      if (candidate.isNpx) {
        final npx = await which('npx');
        if (npx == null) continue;
        return AcpLaunchCandidate(
          const [],
          [npx, ...candidate.argv.sublist(1)],
        );
      }
      final found = <String, String>{};
      var allFound = true;
      for (final exe in candidate.execs) {
        final path = await which(exe);
        if (path == null) {
          allFound = false;
          break;
        }
        found[exe] = path;
      }
      if (!allFound) continue;
      final argv = <String>[];
      for (final arg in candidate.argv) {
        argv.add(arg == '{exe}' ? found[candidate.execs.first]! : arg);
      }
      return AcpLaunchCandidate(const [], argv);
    }
    return null;
  }

  /// 目录全量探测（不 spawn，只看可启动形态）。
  ///
  /// [catalog] 缺省 = 全局 [acpCatalog]；测试/注入运行时传私有表以封闭断言。
  Future<List<AcpAgentAvailability>> detect({
    List<AcpCatalogEntry>? catalog,
  }) async {
    final out = <AcpAgentAvailability>[];
    for (final entry in catalog ?? acpCatalog) {
      final resolved = await resolveCandidate(entry);
      String? cliPath;
      for (final candidate in entry.candidates) {
        for (final exe in candidate.execs) {
          if (exe == 'npx') continue;
          cliPath ??= await which(exe);
        }
      }
      final command = resolved?.argv ?? const <String>[];
      out.add(AcpAgentAvailability(
        id: entry.id,
        name: entry.name,
        installed: resolved != null || cliPath != null,
        selectable: command.isNotEmpty && !entry.grayed,
        note: entry.note,
        executable: cliPath,
        command: command,
        via: resolved == null
            ? ''
            : resolved.isNpx
                ? 'npx-adapter'
                : (command.length > 1 ? 'native' : 'adapter'),
        grayed: entry.grayed,
      ));
    }
    return out;
  }
}

// ============================================================
// 权限
// ============================================================

/// 一个权限选项（agent 提供）。
class AcpPermissionOption {
  const AcpPermissionOption({
    required this.optionId,
    required this.name,
    required this.kind,
  });

  final String optionId;
  final String name;
  final String kind;
}

/// 一次权限请求。
class AcpPermissionRequest {
  const AcpPermissionRequest({
    required this.sessionId,
    required this.title,
    required this.options,
  });

  final String sessionId;
  final String title;
  final List<AcpPermissionOption> options;

  /// `allow` 类选项（kind 含 allow）。
  AcpPermissionOption? get allowOption {
    for (final option in options) {
      if (option.kind.contains('allow')) return option;
    }
    return null;
  }

  /// `reject` 类选项（kind 含 reject/deny/cancel）。
  AcpPermissionOption? get rejectOption {
    for (final option in options) {
      if (option.kind.contains('reject') ||
          option.kind.contains('deny') ||
          option.kind.contains('cancel')) {
        return option;
      }
    }
    return null;
  }
}

/// 权限裁决（`selected` + optionId，或 `cancelled`）。
class AcpPermissionDecision {
  const AcpPermissionDecision.selected(String this.optionId) : outcome = 'selected';
  const AcpPermissionDecision.cancelled()
      : outcome = 'cancelled',
        optionId = null;

  final String outcome;
  final String? optionId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'outcome': <String, dynamic>{
          'outcome': outcome,
          if (optionId != null) 'optionId': optionId,
        },
      };
}

/// 权限处理器：界面弹确认框后返回裁决。没有处理器 = 默认拒绝。
typedef AcpPermissionHandler = Future<AcpPermissionDecision> Function(
    AcpPermissionRequest request);

// ============================================================
// JSON-RPC 2.0（newline-delimited）
// ============================================================

class _RpcPeer {
  _RpcPeer(this._process, {required this.onRequest, required this.onNotification, required this.onClosed});

  final Process _process;
  final FutureOr<Object?> Function(String method, Map<String, dynamic> params) onRequest;
  final void Function(String method, Map<String, dynamic> params) onNotification;
  final void Function() onClosed;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  late final StreamSubscription<String> _sub;
  int _seq = 0;
  bool _closed = false;

  void start() {
    _sub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: (_) {}, onDone: _handleDone);
  }

  void _handleDone() {
    if (_closed) return;
    _closed = true;
    final pending = List<Completer<Map<String, dynamic>>>.from(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(const AcpFailure('acp_agent_exited'));
      }
    }
    onClosed();
  }

  Future<void> _handleLine(String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return;
      message = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return; // 脏行不让整条管道停摆
    }
    final id = message['id'];
    final method = message['method'];
    if (method is String) {
      final params = message['params'] is Map
          ? Map<String, dynamic>.from(message['params'] as Map)
          : <String, dynamic>{};
      if (id != null) {
        // agent → client 请求（权限 / fs）。
        try {
          final result = await onRequest(method, params);
          _write(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});
        } on _RpcError catch (error) {
          _write(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{'code': error.code, 'message': error.message},
          });
        } catch (error) {
          _write(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{'code': -32603, 'message': '$error'},
          });
        }
        return;
      }
      onNotification(method, params);
      return;
    }
    if (id is int || id is String) {
      final completer = _pending.remove(id is int ? id : int.tryParse('$id'));
      if (completer == null || completer.isCompleted) return;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(
          AcpFailure('acp_rpc_error', '${error['code']}: ${error['message']}'),
        );
        return;
      }
      final result = message['result'];
      completer.complete(result is Map
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{'result': result});
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 60),
  ]) {
    if (_closed) {
      return Future.error(const AcpFailure('acp_agent_exited'));
    }
    _seq += 1;
    final id = _seq;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    });
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw const AcpFailure('acp_agent_timeout');
    });
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    if (_closed) return;
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  void _write(Map<String, dynamic> message) {
    try {
      _process.stdin.write('${jsonEncode(message)}\n');
      // 不 await：stdin.flush 是 Future，但行协议按序落盘即可；异常由
      // 进程退出路径统一呈现（_handleDone → acp_agent_exited）。
      unawaited(_process.stdin.flush().catchError((_) {}));
    } catch (_) {}
  }

  Future<void> dispose() async {
    _closed = true;
    await _sub.cancel();
    final pending = List<Completer<Map<String, dynamic>>>.from(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(const AcpFailure('acp_agent_exited'));
      }
    }
  }
}

class _RpcError implements Exception {
  const _RpcError(this.code, this.message);
  final int code;
  final String message;
}

// ============================================================
// 客户端
// ============================================================

/// 一个 ACP 会话：子进程 + JSON-RPC 管道。
///
/// 生命周期：`start` → 多次 `prompt` → `close`。会话进程在关闭/退出后不可
/// 复用；上层（store）按「项目 + 智能体」重建。
class AcpClient {
  factory AcpClient({
    AcpHost? host,
    AcpPathResolver? resolver,
    AcpPermissionHandler? onPermission,
    void Function(String label, String detail)? onNote,
    List<AcpCatalogEntry>? catalog,
  }) {
    final resolvedHost = host ?? SystemAcpHost();
    return AcpClient._(
      resolvedHost,
      resolver ?? AcpPathResolver(host: resolvedHost),
      onPermission,
      onNote,
      catalog ?? acpCatalog,
    );
  }

  AcpClient._(this.host, this.resolver, this.onPermission, this.onNote, this.catalog);

  final AcpHost host;
  final AcpPathResolver resolver;

  /// 权限处理器（界面确认框）；null = 默认拒绝。
  final AcpPermissionHandler? onPermission;

  /// 过程提示（权限、越界拒绝等）；上层可落时间线。
  final void Function(String label, String detail)? onNote;

  /// 可启动目录（默认 [acpCatalog]；测试注入假智能体条目）。
  final List<AcpCatalogEntry> catalog;

  Process? _process;
  _RpcPeer? _peer;
  String? _remoteSession;
  String? get remoteSessionId => _remoteSession;
  String _workspace = '';
  int _promptSeq = 0;
  int _toolSeq = 0;
  bool _closed = false;

  /// 当前是否是能 spawn 进程的宿主（手机/平板 false）。
  static bool isSupportedHost(AcpHost host) => host.isDesktop;

  bool get isRunning => _process != null && !_closed;

  /// 建立会话：spawn → initialize → session/new。
  ///
  /// [agentId] 必须是 [acpCatalog] 的 id；[workspace] 是 agent 的工作目录
  /// （不存在会创建）。失败时已 spawn 的进程就地终止，不留孤儿。
  Future<Map<String, dynamic>> start({
    required String agentId,
    required String workspace,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isSupportedHost(host)) {
      throw const AcpFailure('acp_desktop_only');
    }
    if (_process != null) {
      await close();
    }
    final entry = catalog.firstWhere(
      (e) => e.id == agentId,
      orElse: () => throw const AcpFailure('acp_agent_not_found'),
    );
    if (entry.grayed) throw AcpFailure('acp_agent_grayed', entry.note);
    final candidate = await resolver.resolveCandidate(entry);
    if (candidate == null || candidate.argv.isEmpty) {
      throw AcpFailure('acp_agent_not_startable', entry.note);
    }
    final directory = Directory(workspace);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    _workspace = directory.absolute.path;
    final env = await resolver.childEnvironment();

    final Process process;
    try {
      process = await host.spawn(
        candidate.argv,
        workingDirectory: _workspace,
        environment: env,
      );
    } catch (error) {
      throw AcpFailure('acp_agent_not_startable', '$error');
    }
    _process = process;
    _closed = false;
    // stderr 必须有人读（无人消费的 PIPE 写满即死锁）——读完丢弃。
    unawaited(process.stderr.drain<void>().catchError((_) {}));
    final peer = _RpcPeer(
      process,
      onRequest: _handleAgentRequest,
      onNotification: _handleNotification,
      onClosed: _handleProcessClosed,
    );
    _peer = peer;
    peer.start();
    try {
      await peer.call(
        'initialize',
        <String, dynamic>{
          'protocolVersion': 1,
          'clientCapabilities': <String, dynamic>{
            'fs': <String, dynamic>{'readTextFile': true, 'writeTextFile': true},
          },
        },
        timeout,
      );
      final session = await peer.call(
        'session/new',
        <String, dynamic>{'cwd': _workspace, 'mcpServers': <dynamic>[]},
        timeout,
      );
      final id = session['sessionId'];
      if (id is! String || id.isEmpty) {
        throw const AcpFailure('acp_agent_not_startable', 'missing sessionId');
      }
      _remoteSession = id;
      return <String, dynamic>{'ok': true, 'sessionId': id, 'agent': agentId};
    } catch (error) {
      // 失败路径就地终止已 spawn 的 CLI：会话未入注册表，close 永不可达。
      await _killProcess();
      throw error is AcpFailure ? error : AcpFailure('acp_agent_not_startable', '$error');
    }
  }

  /// 发一轮 prompt。返回事件流（每个事件带本轮 `promptId`，即 run id）。
  ///
  /// 事件形状与内置循环同族：
  /// assistant_delta / thinking_delta / tool_start / tool_end / note /
  /// done{stopReason} / failed{error}。
  Stream<Map<String, dynamic>> prompt(String text) {
    final peer = _peer;
    final remote = _remoteSession;
    if (_activePrompt != null) {
      // 并发 prompt 会替换事件汇、串掉两轮的归属；宁可显式拒绝。
      return Stream<Map<String, dynamic>>.fromIterable(<Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'failed',
          'error': 'acp_prompt_busy',
          'message': acpFailureMessage('acp_prompt_busy'),
          'promptId': _promptSeq,
        },
      ]);
    }
    if (peer == null || remote == null) {
      return Stream<Map<String, dynamic>>.fromIterable([
        <String, dynamic>{
          'type': 'failed',
          'error': 'acp_session_not_started',
          'message': acpFailureMessage('acp_session_not_started'),
        },
      ]);
    }
    _promptSeq += 1;
    final promptId = _promptSeq;
    final controller = StreamController<Map<String, dynamic>>();
    final events = <Map<String, dynamic>>[];
    void emit(Map<String, dynamic> event) {
      final framed = <String, dynamic>{...event, 'promptId': promptId};
      events.add(framed);
      if (!controller.isClosed) controller.add(framed);
    }

    _activePrompt = _ActivePrompt(promptId, emit);
    // 异步跑，先把 Stream 交出去（listen 前的事件进缓冲）。
    unawaited(() async {
      try {
        final result = await peer.call(
          'session/prompt',
          <String, dynamic>{
            'sessionId': remote,
            'prompt': <dynamic>[
              <String, dynamic>{'type': 'text', 'text': text},
            ],
          },
          const Duration(minutes: 10),
        );
        final stop = result['stopReason']?.toString() ?? 'end_turn';
        emit(<String, dynamic>{'type': 'done', 'stopReason': stop});
      } on AcpFailure catch (error) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': error.code,
          'message': acpFailureMessage(error.code),
          'detail': error.detail,
        });
      } catch (error) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': 'acp_rpc_error',
          'message': acpFailureMessage('acp_rpc_error'),
          'detail': '$error',
        });
      } finally {
        _activePrompt = null;
        if (!controller.isClosed) await controller.close();
      }
    }());
    return controller.stream;
  }

  /// 取消在飞的一轮（agent 侧 stopReason=cancelled）。
  Future<void> cancel() async {
    final peer = _peer;
    final remote = _remoteSession;
    if (peer == null || remote == null) return;
    peer.notify('session/cancel', <String, dynamic>{'sessionId': remote});
  }

  /// 关闭会话并终止进程（幂等）。
  Future<void> close() async {
    final peer = _peer;
    final remote = _remoteSession;
    if (peer != null && remote != null) {
      try {
        peer.notify('session/cancel', <String, dynamic>{'sessionId': remote});
      } catch (_) {}
    }
    await peer?.dispose();
    _peer = null;
    _remoteSession = null;
    _activePrompt = null;
    await _killProcess();
  }

  Future<void> _killProcess() async {
    final process = _process;
    _process = null;
    _closed = true;
    if (process == null) return;
    if (process.kill(ProcessSignal.sigterm)) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    } else {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  _ActivePrompt? _activePrompt;

  void _handleProcessClosed() {
    // 在飞的 prompt 由 `_RpcPeer._handleDone` 以 acp_agent_exited 结束
    // pending 调用，prompt 的 catch 统一发 failed——这里不再重复发事件。
    _process = null;
    _peer = null;
    _remoteSession = null;
  }

  /// `session/update` 通知 → 事件。
  void _handleNotification(String method, Map<String, dynamic> params) {
    if (method != 'session/update') return;
    final update = params['update'];
    if (update is! Map) return;
    final kind = (update['sessionUpdate'] ?? '').toString();
    switch (kind) {
      case 'agent_message_chunk':
        final text = _contentText(update['content']);
        if (text.isNotEmpty) {
          _activePrompt?.emit(<String, dynamic>{'type': 'assistant_delta', 'text': text});
        }
        break;
      case 'agent_thought_chunk':
        final text = _contentText(update['content']);
        if (text.isNotEmpty) {
          _activePrompt?.emit(<String, dynamic>{'type': 'thinking_delta', 'text': text});
        }
        break;
      case 'user_message_chunk':
        break; // 回显忽略
      case 'tool_call':
        _toolSeq += 1;
        _activePrompt?.emit(<String, dynamic>{
          'type': 'tool_start',
          'tool': update['title'] ?? update['kind'] ?? 'tool',
          'seq': _toolSeq,
        });
        break;
      case 'tool_call_update':
        final status = (update['status'] ?? '').toString();
        if (status == 'completed' || status == 'failed') {
          _activePrompt?.emit(<String, dynamic>{
            'type': 'tool_end',
            'ok': status == 'completed',
            'title': (update['title'] ?? '').toString(),
          });
        }
        break;
      case 'plan':
        final entries = update['entries'];
        final bits = <String>[];
        if (entries is List) {
          for (final item in entries.take(6)) {
            if (item is Map && item['content'] != null) {
              bits.add(item['content'].toString());
            }
          }
        }
        _activePrompt?.emit(<String, dynamic>{
          'type': 'note',
          'label': '计划更新',
          'detail': bits.join(' · '),
        });
        break;
      default:
        break;
    }
  }

  static String _contentText(Object? content) {
    if (content is Map) {
      final text = content['text'];
      if (text is String) return text;
    }
    if (content is String) return content;
    return '';
  }

  /// agent → client 请求：权限 + 工作区内文件读写。
  Future<Object?> _handleAgentRequest(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'session/request_permission':
        return _answerPermission(params);
      case 'fs/read_text_file':
        return _readTextFile(params);
      case 'fs/write_text_file':
        return _writeTextFile(params);
      default:
        throw _RpcError(-32601, 'method not supported: $method');
    }
  }

  Future<Map<String, dynamic>> _answerPermission(Map<String, dynamic> params) async {
    final rawOptions = params['options'];
    final options = <AcpPermissionOption>[];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is! Map) continue;
        options.add(AcpPermissionOption(
          optionId: (item['optionId'] ?? '').toString(),
          name: (item['name'] ?? '').toString(),
          kind: (item['kind'] ?? '').toString(),
        ));
      }
    }
    final toolCall = params['toolCall'];
    final title = toolCall is Map ? (toolCall['title'] ?? '').toString() : '';
    final request = AcpPermissionRequest(
      sessionId: (params['sessionId'] ?? '').toString(),
      title: title,
      options: options,
    );
    AcpPermissionDecision decision;
    final handler = onPermission;
    if (handler == null) {
      // 安全缺省：没有确认界面就不放行（明确告知，不静默）。
      decision = AcpPermissionDecision.cancelled();
      onNote?.call('权限未确认', '没有确认界面，已先停住：${title.isEmpty ? '这次操作' : title}');
    } else {
      decision = await handler(request);
      onNote?.call(
        decision.outcome == 'selected' ? '权限已确认' : '权限已拒绝',
        title.isEmpty ? '这次操作' : title,
      );
    }
    return decision.toJson();
  }

  /// 工作区路径解析：越界返回 null（调用方转成 JSON-RPC 错误）。
  ///
  /// 相对路径按工作区解析；`..` 段先折叠再比较前缀（符号链接目标若存在
  /// 优先用真实路径）——两道合起来才能挡住 `workspace/../secret`。
  File? _resolveWorkspacePath(Object? raw) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return null;
    final root = _normalizePath(Directory(_workspace).absolute.path);
    // macOS 的 TMPDIR（/var → /private/var）等工作区本身可能经过符号链接：
    // 真实路径与字面路径都要接受，否则工作区内的读写会被误判越界。
    var rootReal = root;
    try {
      rootReal = _normalizePath(Directory(root).resolveSymbolicLinksSync());
    } catch (_) {}
    bool inside(String path) =>
        path == root ||
        path.startsWith('$root${Platform.pathSeparator}') ||
        path == rootReal ||
        path.startsWith('$rootReal${Platform.pathSeparator}');
    final absolute =
        _normalizePath(File(value).isAbsolute ? value : '$root${Platform.pathSeparator}$value');
    if (!inside(absolute)) return null;
    final file = File(absolute);
    try {
      final real = _normalizePath(file.resolveSymbolicLinksSync());
      if (!inside(real)) return null;
      return File(real);
    } catch (_) {
      // 目标还不存在（写新文件）：用折叠后的绝对路径。
      return file;
    }
  }

  /// 折叠 `.` / `..`（不访问文件系统）。
  static String _normalizePath(String path) {
    final separator = Platform.pathSeparator;
    final absolute = path.startsWith(separator);
    final parts = <String>[];
    for (final segment in path.split(separator)) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(segment);
    }
    final joined = parts.join(separator);
    return absolute ? '$separator$joined' : joined;
  }

  Map<String, dynamic> _readTextFile(Map<String, dynamic> params) {
    final file = _resolveWorkspacePath(params['path']);
    if (file == null || !file.existsSync()) {
      onNote?.call('读取被拒绝', '文件在工作区之外或不存在，已阻止');
      throw const _RpcError(-32001, 'path outside workspace');
    }
    final lines = file.readAsLinesSync();
    final line = params['line'];
    final limit = params['limit'];
    final start = (line is num && line > 0) ? line.toInt() - 1 : 0;
    final end = (limit is num && limit > 0)
        ? (start + limit.toInt()).clamp(0, lines.length)
        : lines.length;
    final content = lines.sublist(start.clamp(0, lines.length), end).join('\n');
    return <String, dynamic>{'content': content};
  }

  Map<String, dynamic> _writeTextFile(Map<String, dynamic> params) {
    final file = _resolveWorkspacePath(params['path']);
    if (file == null) {
      onNote?.call('写入被拒绝', '目标在工作区之外，已阻止');
      throw const _RpcError(-32001, 'path outside workspace');
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync((params['content'] ?? '').toString(), flush: true);
    return <String, dynamic>{};
  }
}

class _ActivePrompt {
  _ActivePrompt(this.id, this.emit);
  final int id;
  final void Function(Map<String, dynamic> event) emit;
}

// ============================================================
// 协议探测（initialize + session/new 实测）
// ============================================================

/// 一次探测的结论。
class AcpProbeResult {
  const AcpProbeResult(this.state, {this.detail = ''});

  /// `verified` | `failed` | `unsupported`。
  final String state;
  final String detail;

  bool get verified => state == 'verified';

  Map<String, dynamic> toJson() => <String, dynamic>{'state': state, 'detail': detail};
}

/// 实测一个目录项能否完成 ACP 握手（spawn → initialize → session/new → close）。
///
/// 与「只看文件存在」的 [AcpPathResolver.detect] 互补：npx 首拉、需要登录的
/// CLI、协议不兼容的适配器只有真跑一次才知道。失败不留进程、不留目录。
Future<AcpProbeResult> probeAcpAgent({
  required AcpCatalogEntry entry,
  AcpHost? host,
  AcpPathResolver? resolver,
  String? workspace,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final resolvedHost = host ?? SystemAcpHost();
  if (!resolvedHost.isDesktop) {
    return const AcpProbeResult('unsupported', detail: 'desktop only');
  }
  if (entry.grayed) {
    return AcpProbeResult('failed', detail: entry.note);
  }
  final ownsWorkspace = workspace == null;
  final probeWorkspace =
      workspace ?? Directory.systemTemp.createTempSync('acp-probe-').path;
  final client = AcpClient(
    host: resolvedHost,
    resolver: resolver ?? AcpPathResolver(host: resolvedHost),
    catalog: <AcpCatalogEntry>[entry],
  );
  try {
    final started = await client.start(
      agentId: entry.id,
      workspace: probeWorkspace,
      timeout: timeout,
    );
    return AcpProbeResult(
      'verified',
      detail: 'initialize+session/new ok (${started['sessionId']})',
    );
  } on AcpFailure catch (error) {
    return AcpProbeResult('failed', detail: '${error.code}: ${error.detail}');
  } catch (error) {
    return AcpProbeResult('failed', detail: '$error');
  } finally {
    await client.close();
    if (ownsWorkspace) {
      try {
        Directory(probeWorkspace).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
