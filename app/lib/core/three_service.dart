/// 3D 场景工作台的本地面（批次 06）。
///
/// 这一层把过去由外部服务承担的 3D 制作流程整体搬到客户端进程内：
///
///  * **规范先行**：新建项目先让模型产出一份场景规范（组件清单 / 材质 /
///    相机 / 验收标准），没有规范就没有代码（fail-closed）。规范存在项目目录的
///    `three-spec.json` 里，可以手工编辑后回灌。
///  * **分六层推进**：占位 → 结构 → 造型 → 材质 → 灯光 → 交互。每一层只解
///    当前层，进度权威是 `build-state.json`（不是对话记忆）。每层都有修复轮上限
///    （[threeLoopMax]）；超限即 blocked，出路是调整规范后重来，而不是糊一个
///    通用场景。
///  * **确定性反馈先行**：预览页回传三类反馈——执行错误（计入修复轮）、
///    场景测量（记录）、截图（落 `evidence/`，是推进的必要证据）。四方位
///    取证一次出四张，单视角不作为模型证据。
///  * **证据与历史**：`history.jsonl` 逐条记账（新建 / 生成 / 反馈 / 推进 /
///    阻塞 / 调整规范），最近 50 条随项目快照返回。
///
/// 存储布局（全部在 [root] 下，一项目一目录）：
/// ```
/// <root>/<项目名>/
///   three-spec.json   场景规范
///   build-state.json  进度权威（原子写）
///   scene.js          场景代码（预览页动态 import）
///   preview.html      自包含预览页（挂载时把渲染库与场景源码内联进去）
///   three.module.js   渲染库（与宿主页同目录——WebKit 的读取范围就是父目录）
///   evidence/         截图证据
///   history.jsonl     记账
/// ```
///
/// 三条边界：
///  1. 模型调用只走 `ai_sdk`（[defaultThreeLlmCall]），不经过任何本地端口或
///     内部路由；测试注入 [ThreeLlmCall]，不碰网络。
///  2. 预览页与渲染库从**应用资源**拷贝到项目目录，离线可用，绝不引用远端
///     CDN（unpkg 等一律不出现）。
///  3. 用户可见文案不在这里拼；[ThreeFailure.code] 是内部代号，界面经
///     [threeFailureMessage] 映射成一句人话，原始诊断只进折叠的「技术详情」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_sdk_dart/ai_sdk_dart.dart' show TimeoutConfiguration, generateText;
import 'package:ai_sdk_openai/ai_sdk_openai.dart' show OpenAIProvider;
import 'package:flutter/services.dart' show rootBundle;

import 'app_paths.dart';
import 'platform_capabilities.dart';

// ---------------------------------------------------------------------------
// 常量：分层、上限、资源
// ---------------------------------------------------------------------------

/// 每一层的修复轮上限。超限即阻塞（保留证据，先改规范）。
const int threeLoopMax = 3;

/// 预览宿主页资源键。
const String threePreviewAssetKey = 'assets/three/preview.html';

/// 渲染库资源键（vendored r160，1,272,972 B）。
const String threeModuleAssetKey = 'assets/three/three.module.js';

/// three-live 资源键（vendored 1.4.0，经典脚本，含 file:// 引擎内联补丁）。
///
/// 预览页把它内联进 `#three-live-runtime`：`allow-client-scripts` 的沙箱
/// Worker 以该脚本的 textContent 作为自己的引擎源（见 assets/three/vendor/
/// NOTICE.md）。不校验字节长度——上游每次 patch 版本都可能变；资源缺失会在
/// [preparePreview] 里显性失败。
const String threeLiveAssetKey = 'assets/three/vendor/three-live.min.js';

/// 渲染库的 sha256（与 `scripts/sync_three_assets.dart` 的锚点一致）。
///
/// 只用于诊断与同步脚本对账：运行时不重新校验 1.2MB 资源，但拷贝到项目
/// 目录后会比对字节长度，资源被裁剪时立刻显性失败而不是让预览页白屏。
const String threeModuleSha256 =
    '76dea8151bc9352aef3528b4262e249b2604f62543828328db978d060d61a495';

/// 渲染库字节数（[threeModuleSha256] 的同一份产物）。
const int threeModuleByteLength = 1272972;

/// 单张截图证据（解码后的 PNG 字节）上限：8 MiB。
///
/// 预览页是模型生成的执行面，属于不可信输入：桥消息里的 base64 载荷在
/// 落盘前必须有硬上限，否则一条消息就能把磁盘写满。
const int threeEvidenceMaxBytes = 8 * 1024 * 1024;

/// 一个项目累计的证据文件上限：48。
///
/// 六层 ×（单视角 + 四方位）约 30 张，留出修复轮余量；到顶后拒绝新截图
/// （已落盘的证据不删——推进门仍要看它们）。
const int threeEvidenceMaxFiles = 48;

/// 一层的定义：内部 id、给模型看的目标、给用户看的名字。
class ThreePassSpec {
  const ThreePassSpec({required this.id, required this.goal, required this.label});

  /// 内部代号（只出现在状态文件与提示词里，绝不直接上屏）。
  final String id;

  /// 这一层要解决什么（进模型提示词）。
  final String goal;

  /// 用户在进度条上看到的名字。
  final String label;
}

/// 六层推进顺序。顺序本身是契约：`build-state.json` 的 passes 与它同序。
const List<ThreePassSpec> threePasses = <ThreePassSpec>[
  ThreePassSpec(
    id: 'blockout',
    goal: '主几何占位（盒子/球/布局块），相机就位，整体构图可辨识',
    label: '占位',
  ),
  ThreePassSpec(
    id: 'structure',
    goal: '组件层级细化：真实几何形状、比例、父子关系（Group 层级）',
    label: '结构',
  ),
  ThreePassSpec(
    id: 'form',
    goal: '细节造型：倒角/轮廓/子部件/表面起伏——身份定义特征在这一层',
    label: '造型',
  ),
  ThreePassSpec(
    id: 'material',
    goal: 'PBR 材质：颜色/roughness/metalness/透明度，按规范材质清单',
    label: '材质',
  ),
  ThreePassSpec(
    id: 'lighting',
    goal: '灯光与环境：主光/补光/背景色/阴影，服务可读性与氛围',
    label: '灯光',
  ),
  ThreePassSpec(
    id: 'interaction',
    goal: '动画与交互：自转/轨道/呼吸/点击响应（clock 驱动）',
    label: '交互',
  ),
];

/// 用户可见的层名；`done` 表示全部完成，未知 id 收回一个中性词。
String threePassLabel(Object? id) {
  if (id == 'done') return '完成';
  for (final pass in threePasses) {
    if (pass.id == id) return pass.label;
  }
  return '进行中';
}

/// 某一层的目标（提示词用）；未知 id 返回空串。
String threePassGoal(Object? id) {
  for (final pass in threePasses) {
    if (pass.id == id) return pass.goal;
  }
  return '';
}

/// 初始进度：第一层待生成，其余排好队。
Map<String, dynamic> initialThreeState() => <String, dynamic>{
      'current': threePasses.first.id,
      'passes': <Map<String, dynamic>>[
        for (final pass in threePasses)
          <String, dynamic>{
            'id': pass.id,
            'status': 'pending',
            'attempts': 0,
            'evidence': <String>[],
          },
      ],
      'loop_max': threeLoopMax,
      'blocked': false,
      'blocked_reason': '',
    };

/// 没有代码时的骨架场景：让首帧预览不是空白，也能先收一轮环境测量。
const String threeSceneSkeleton = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const grid = new THREE.GridHelper(20, 20, 0x33415a, 0x1b2338);
  scene.add(grid);
  return { metrics: { skeleton: true } };
}
''';

// ---------------------------------------------------------------------------
// 失败模型：内部代号 + 原始诊断
// ---------------------------------------------------------------------------

/// 一次 3D 操作失败。
///
/// [code] 是内部代号（`no_project` / `spec_invalid` / …），**不上屏**；
/// [detail] 是给「技术详情」折叠块看的原始诊断。界面用
/// [threeFailureMessage] 把代号翻成一句人话。
class ThreeFailure implements Exception {
  const ThreeFailure(this.code, [this.detail = '']);

  final String code;
  final String detail;

  @override
  String toString() => 'ThreeFailure($code${detail.isEmpty ? '' : ': $detail'})';
}

/// 内部代号 → 用户可见句子。
///
/// 措辞纪律（`docs/copy-glossary.md`）：不出现实现名、错误码、文件扩展名，
/// 只回答「发生了什么 + 下一步」。
String threeFailureMessage(Object? error) {
  final code = error is ThreeFailure ? error.code : '';
  switch (code) {
    case 'invalid_name':
      return '场景名只能用字母、数字和短横线';
    case 'project_exists':
      return '已经有同名的 3D 项目了，换个名字再试';
    case 'no_project':
      return '没有找到这个 3D 项目';
    case 'brief_empty':
      return '先写一句想做出来的样子';
    case 'spec_invalid':
      return '项目规范还不完整：组件和验收标准都要有';
    case 'spec_parse_failed':
      return '这一次没有拿到可用的规范，请重试';
    case 'spec_corrupt':
      return '规范文件读不出来，可以在「规范」页粘贴一份合法的内容保存';
    case 'code_parse_failed':
      return '这一次没有拿到可用的场景代码，请重试';
    case 'state_corrupt':
      return '进度记录损坏，已经回到第一层重来';
    case 'blocked':
      return '这一层连续失败，先调整规范再继续';
    case 'already_done':
      return '这个 3D 项目已经全部完成了';
    case 'pass_awaiting_feedback':
      return '这一层已经生成，先看预览、截一张图再继续';
    case 'cannot_continue':
      return '先截一张图作为这一层通过的依据';
    case 'evidence_invalid':
      return '这张截图没能保存，请重试';
    case 'evidence_too_large':
      return '这张截图太大了，没能保存，请缩小预览后再试';
    case 'evidence_limit':
      return '这个项目的截图已经够多了，先整理旧项目再继续';
    case 'invalid_feedback_kind':
      return '这次反馈没有识别出来，请重试';
    case 'llm_error':
      return '模型这次没有响应，请稍后重试';
    case 'asset_missing':
      return '预览文件缺失，请重新安装或重新构建应用';
    default:
      return '这次操作没有成功，请重试';
  }
}

// ---------------------------------------------------------------------------
// 模型调用（ai_sdk）
// ---------------------------------------------------------------------------

/// 一次单轮模型调用的入参。
class ThreeLlmRequest {
  const ThreeLlmRequest({
    required this.system,
    required this.prompt,
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    required this.thinkingLevel,
  });

  final String system;
  final String prompt;
  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;
}

/// 模型调用签名（测试注入假实现，不碰网络）。
typedef ThreeLlmCall = Future<String> Function(ThreeLlmRequest request);

/// 模型连接参数（来自设置面板当前选中的服务商/模型）。
class ThreeLlmConfig {
  const ThreeLlmConfig({
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    this.thinkingLevel = 'auto',
  });

  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;

  /// 地址与密钥都在场才谈得上调用。
  bool get isConfigured => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

/// 思考等级 → `reasoning_effort` 取值。
///
/// 逐字对齐 3D 流程原先在外部服务里的语义：只认 `low` / `medium` / `high`，
/// 其余（含 `auto` / 空串 / 开关档 / 大小写不符）一律不注入。
String? threeReasoningEffort(String level) {
  if (level == 'low' || level == 'medium' || level == 'high') return level;
  return null;
}

/// `ai_sdk` 的 providerOptions 形状（null = 不注入）。
Map<String, Map<String, dynamic>>? threeProviderOptions(String level) {
  final effort = threeReasoningEffort(level);
  if (effort == null) return null;
  return <String, Map<String, dynamic>>{
    'openai': <String, dynamic>{'reasoning_effort': effort},
  };
}

/// 默认模型调用：`ai_sdk` 单轮补全，OpenAI 兼容协议。
///
/// 温度 0.4 与旧流程一致（结构化产出要稳，不要发散）。SDK 的异常族统一
/// 包成 [ThreeFailure]——界面只看到一句人话，原始信息进技术详情。
Future<String> defaultThreeLlmCall(ThreeLlmRequest request) async {
  final provider = OpenAIProvider(apiKey: request.apiKey, baseUrl: request.baseUrl);
  try {
    final result = await generateText<Object?>(
      model: provider.call(request.model.isEmpty ? 'gpt-5.1' : request.model),
      system: request.system,
      prompt: request.prompt,
      temperature: 0.4,
      providerOptions: threeProviderOptions(request.thinkingLevel),
      timeout: const TimeoutConfiguration(total: Duration(minutes: 3)),
    );
    return result.text;
  } catch (error) {
    throw ThreeFailure('llm_error', '$error');
  } finally {
    provider.dispose();
  }
}

// ---------------------------------------------------------------------------
// 资源装载
// ---------------------------------------------------------------------------

/// 资源读取签名：键 → 字节（测试注入内存资源，避免依赖 asset bundle）。
typedef ThreeAssetLoader = Future<Uint8List> Function(String key);

Future<Uint8List> _bundleAssetLoader(String key) async {
  try {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (error) {
    throw ThreeFailure('asset_missing', '$key: $error');
  }
}

// ---------------------------------------------------------------------------
// 结果快照
// ---------------------------------------------------------------------------

/// 一个 3D 项目此刻的全貌。
class ThreeProjectSnapshot {
  const ThreeProjectSnapshot({
    required this.name,
    required this.spec,
    required this.state,
    required this.sceneJs,
    required this.history,
    required this.dir,
  });

  final String name;
  final Map<String, dynamic> spec;

  /// 进度权威（原样给出，界面只读）。
  final Map<String, dynamic> state;
  final String sceneJs;

  /// 最近 50 条记账（坏的半行已跳过）。
  final List<Map<String, dynamic>> history;
  final String dir;

  String get current => '${state['current'] ?? ''}';
  bool get blocked => state['blocked'] == true;

  List<Map<String, dynamic>> get passes => <Map<String, dynamic>>[
        for (final pass in (state['passes'] as List? ?? const []))
          if (pass is Map) pass.cast<String, dynamic>(),
      ];
}

/// 项目列表里的一行。
class ThreeProjectEntry {
  const ThreeProjectEntry({required this.name, required this.current, required this.blocked});

  final String name;

  /// 当前层 id；`corrupt` 表示进度文件读不出来（点进去会触发自愈重置）。
  final String current;
  final bool blocked;
}

/// 一次分层的产出。
class ThreePassResult {
  const ThreePassResult({
    required this.pass,
    required this.stale,
    required this.chars,
    required this.state,
  });

  final String pass;

  /// true = 生成期间进度已被推进，代码落盘但**没有**改写状态。
  final bool stale;
  final int chars;
  final Map<String, dynamic> state;
}

/// 一次反馈的产出。
class ThreeFeedbackResult {
  const ThreeFeedbackResult({
    required this.status,
    required this.pass,
    required this.attempts,
    required this.state,
  });

  final String status;
  final String pass;
  final int attempts;
  final Map<String, dynamic> state;
}

/// 一次「通过并继续」的产出。
class ThreeContinueResult {
  const ThreeContinueResult({required this.current, required this.done});

  final String current;
  final bool done;
}

/// 一次规范回灌的产出。
class ThreeSpecSaveResult {
  const ThreeSpecSaveResult({required this.unblocked, required this.state});

  /// true = 本次保存顺带解除了阻塞并复位了失败层。
  final bool unblocked;
  final Map<String, dynamic> state;
}

/// 预览三件套落盘后的位置（同目录，供 WebView 直接按文件加载）。
class ThreePreviewBundle {
  const ThreePreviewBundle({
    required this.htmlPath,
    required this.scenePath,
    required this.modulePath,
  });

  final String htmlPath;
  final String scenePath;
  final String modulePath;
}

// ---------------------------------------------------------------------------
// ThreeUI 组件画廊（vendored ThreeUI Community 1.1.0）
// ---------------------------------------------------------------------------

/// ThreeUI 组件清单资源键（vendored 自包含 HTML 页面，见 threeui/NOTICE.md）。
const String threeUiCatalogAssetKey = 'assets/three/threeui/catalog.json';

/// 画廊清单的取用区间：小于 8 说明 vendored 资产被裁掉，超过 12 说明清单
/// 没同步（应用包会白白变大）。不是硬门：运行时不因为数量不对而空屏，
/// 由测试与 [threeUiCatalogHealth] 把问题暴露出来。
const int threeUiMinComponents = 8;
const int threeUiMaxComponents = 12;

/// 画廊里的一张卡片：一个自包含 ThreeUI 页面。
class ThreeUiComponent {
  const ThreeUiComponent({
    required this.id,
    required this.name,
    required this.description,
    required this.assetKey,
    required this.hint,
  });

  /// 稳定 id（小写字母/数字/短横线；卡片 Key 与测试都用它）。
  final String id;

  /// 用户可见名称。
  final String name;

  /// 一句说明（用户可见，遵守文案表）。
  final String description;

  /// Flutter 资源键：`assets/three/threeui/<file>.html`。
  final String assetKey;

  /// 缩略提示（列表里的一行小字，不做截图）。
  final String hint;
}

/// 解析 ThreeUI 画廊清单。
///
/// 清单是应用资源（不是用户输入），但仍按不可信输入处理：字段缺失 / 命名
/// 不合法 / 文件不是同目录 HTML 的条目直接丢弃，不把坏路径递给 WebView。
/// 全部条目都坏时显性失败（空画廊比报错更难排查）。
List<ThreeUiComponent> parseThreeUiCatalog(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (error) {
    throw ThreeFailure('asset_missing', 'threeui catalog: $error');
  }
  if (decoded is! Map) {
    throw ThreeFailure('asset_missing', 'threeui catalog: not an object');
  }
  final entries = decoded['components'];
  if (entries is! List) {
    throw ThreeFailure('asset_missing', 'threeui catalog: components missing');
  }
  final idPattern = RegExp(r'^[a-z0-9-]+$');
  final seen = <String>{};
  final out = <ThreeUiComponent>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    final id = '${entry['id'] ?? ''}'.trim();
    final name = '${entry['name'] ?? ''}'.trim();
    final description = '${entry['description'] ?? ''}'.trim();
    final file = '${entry['file'] ?? ''}'.trim();
    final hint = '${entry['hint'] ?? ''}'.trim();
    if (id.isEmpty || name.isEmpty || description.isEmpty) continue;
    if (!idPattern.hasMatch(id) || !seen.add(id)) continue;
    // 只允许同目录 .html：清单不能把 WebView 引到目录外或远端 URL。
    if (!file.endsWith('.html') || file.contains('/') || file.contains('\\')) continue;
    out.add(ThreeUiComponent(
      id: id,
      name: name,
      description: description,
      assetKey: 'assets/three/threeui/$file',
      hint: hint,
    ));
  }
  if (out.isEmpty) {
    throw ThreeFailure('asset_missing', 'threeui catalog: no valid components');
  }
  return out;
}

/// 清单健康度：`null` 表示数量落在取用区间内，否则是一句内部诊断
/// （只进测试/技术详情，不上屏）。
String? threeUiCatalogHealth(int count) {
  if (count < threeUiMinComponents) {
    return 'threeui catalog: only $count components (< $threeUiMinComponents)';
  }
  if (count > threeUiMaxComponents) {
    return 'threeui catalog: $count components (> $threeUiMaxComponents)';
  }
  return null;
}

// ---------------------------------------------------------------------------
// 服务本体
// ---------------------------------------------------------------------------

/// 本机 3D 工作台（项目目录 + 状态机 + 规范 + 证据）。
///
/// 无状态服务：所有进度都在磁盘上，跨视图/跨进程切换不会丢；并发一致性靠
/// 「await 后重读再按层键控写回」（[runPass]）而不是内存锁。
class ThreeService {
  ThreeService({
    required Directory root,
    ThreeLlmCall? llm,
    ThreeAssetLoader? assets,
  })  : _root = root,
        _llm = llm ?? defaultThreeLlmCall,
        _assets = assets ?? _bundleAssetLoader;

  /// 生产入口：`<用户文档>/NoNDesign/3d`。
  ///
  /// 根目录**不在这里创建**：目录在第一次真正写入时才出现（`newProject` /
  /// 证据落盘各自建父目录）。这样只读浏览、空项目、以及测试里注入的临时根
  /// 都不会在用户的文档目录里留下空壳。
  ///
  /// [root] 显式给定时不碰平台目录（测试/嵌入式宿主）。
  static Future<ThreeService> open({
    ThreeLlmCall? llm,
    ThreeAssetLoader? assets,
    Directory? root,
  }) async {
    final dir = root ?? Directory('${(await AppPaths.projectsRoot()).path}/3d');
    return ThreeService(root: dir, llm: llm, assets: assets);
  }

  final Directory _root;
  final ThreeLlmCall _llm;
  final ThreeAssetLoader _assets;

  /// 所有 3D 项目的父目录。
  Directory get root => _root;

  static final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_-]+$');

  /// 项目目录（名称白名单之外一律拒绝——名称来自用户输入，是不可信字符串）。
  Directory projectDir(String name) {
    if (name.isEmpty || !_namePattern.hasMatch(name)) {
      throw ThreeFailure('invalid_name', name);
    }
    return Directory('${_root.path}/$name');
  }

  /// 预览宿主页的绝对路径（给 WebView 按文件加载用）。
  String previewHtmlPath(String name) => '${projectDir(name).path}/preview.html';

  // -- 读 -------------------------------------------------------------------

  /// 项目全貌。状态文件损坏会自愈（备份 `.bak` 后回到初始进度）；
  /// 规范文件损坏则如实报错——规范是生成依据，静默清空会让后续层瞎写。
  Future<ThreeProjectSnapshot> readProject(String name) async {
    final dir = projectDir(name);
    if (!dir.existsSync()) throw ThreeFailure('no_project', name);
    final specFile = File('${dir.path}/three-spec.json');
    final spec = specFile.existsSync() ? _readSpecSync(name) : <String, dynamic>{};
    final sceneFile = File('${dir.path}/scene.js');
    final scene = sceneFile.existsSync() ? sceneFile.readAsStringSync() : '';
    return ThreeProjectSnapshot(
      name: name,
      spec: spec,
      state: _readStateSync(name),
      sceneJs: scene,
      history: _readHistory(name),
      dir: dir.path,
    );
  }

  /// 全部项目（按名字排序；状态损坏的项目标 `corrupt`，不影响其他行）。
  Future<List<ThreeProjectEntry>> listProjects() async {
    final entries = <ThreeProjectEntry>[];
    if (!_root.existsSync()) return entries;
    final dirs = _root
        .listSync()
        .whereType<Directory>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final dir in dirs) {
      final stateFile = File('${dir.path}/build-state.json');
      if (!stateFile.existsSync()) continue;
      final name = _basename(dir.path);
      try {
        final decoded = jsonDecode(stateFile.readAsStringSync());
        if (decoded is! Map) throw const FormatException('not an object');
        entries.add(ThreeProjectEntry(
          name: name,
          current: '${decoded['current'] ?? ''}',
          blocked: decoded['blocked'] == true,
        ));
      } catch (_) {
        entries.add(ThreeProjectEntry(name: name, current: 'corrupt', blocked: true));
      }
    }
    return entries;
  }

  // -- 新建 / 生成 / 反馈 / 推进 --------------------------------------------

  /// 规范阶段：一句话目标 → 场景规范 + 初始进度。
  ///
  /// 目录在规范成功之后才创建——模型/解析失败不留半成品目录。
  Future<ThreeProjectSnapshot> newProject({
    required String name,
    required String brief,
    required ThreeLlmConfig config,
  }) async {
    final dir = projectDir(name);
    if (dir.existsSync()) throw ThreeFailure('project_exists', name);
    if (brief.trim().isEmpty) throw ThreeFailure('brief_empty');
    final raw = await _chat(
      system: _specSystemPrompt,
      prompt: brief.trim(),
      config: config,
    );
    final spec = _extractJson(raw);
    if (!_hasNonEmptyList(spec['components']) || !_hasNonEmptyList(spec['acceptance'])) {
      throw ThreeFailure('spec_invalid', 'components/acceptance');
    }
    dir.createSync(recursive: true);
    _atomicWrite(File('${dir.path}/three-spec.json'), _prettyJson(spec));
    final state = initialThreeState();
    _writeState(name, state);
    appendHistory(name, <String, dynamic>{
      'action': 'new',
      'pass': '-',
      'summary': '${spec['summary'] ?? ''}',
    });
    return ThreeProjectSnapshot(
      name: name,
      spec: spec,
      state: state,
      sceneJs: '',
      history: _readHistory(name),
      dir: dir.path,
    );
  }

  /// 生成当前层。
  ///
  /// 门禁顺序与旧流程一致：阻塞 → 已完成 → 当前层不存在 → 待反馈 →
  /// 修复轮超限（超限即落盘 blocked 并拒绝）。模型返回后**重读**磁盘状态，
  /// 按发起时的层 id 键控写回：await 期间到达的反馈（可能已把层标成 blocked）
  /// 不会被旧快照覆盖。
  Future<ThreePassResult> runPass(String name, ThreeLlmConfig config) async {
    final state = _readStateSync(name);
    if (state['blocked'] == true) {
      throw ThreeFailure('blocked', '${state['blocked_reason'] ?? ''}');
    }
    if (state['current'] == 'done') throw ThreeFailure('already_done');
    var current = _passOf(state, state['current']);
    final attempts = _asInt(current['attempts']);
    if (current['status'] == 'generated' && attempts == 0) {
      throw ThreeFailure('pass_awaiting_feedback', '${state['current']}');
    }
    final loopMax = _asInt(state['loop_max'], threeLoopMax);
    if (attempts >= loopMax) {
      current['status'] = 'blocked';
      state['blocked'] = true;
      state['blocked_reason'] =
          '${state['current']} 连续 $attempts 轮未过——保留证据，先调整规范再继续';
      _writeState(name, state);
      appendHistory(name, <String, dynamic>{
        'action': 'blocked',
        'pass': state['current'],
        'summary': state['blocked_reason'],
      });
      throw ThreeFailure('blocked', '${state['blocked_reason']}');
    }
    final pid = '${current['id']}';
    final request = _passPrompt(name);
    final raw = await _chat(system: request.system, prompt: request.prompt, config: config);
    final js = _extractJs(raw);
    _atomicWrite(File('${projectDir(name).path}/scene.js'), js);

    final fresh = _readStateSync(name);
    final freshPass = _passOrNull(fresh, pid);
    if (freshPass == null || fresh['current'] != pid) {
      // 已被推进/越界：代码保留，状态不动，如实回报。
      appendHistory(name, <String, dynamic>{
        'action': 'generate',
        'pass': pid,
        'stale': true,
        'chars': js.length,
      });
      return ThreePassResult(pass: pid, stale: true, chars: js.length, state: fresh);
    }
    freshPass['status'] = 'generated';
    _writeState(name, fresh);
    appendHistory(name, <String, dynamic>{'action': 'generate', 'pass': pid, 'chars': js.length});
    return ThreePassResult(pass: pid, stale: false, chars: js.length, state: fresh);
  }

  /// 预览页回传的三类反馈。
  ///
  ///  * `error`：修复轮 +1，状态转失败；达到上限即阻塞。
  ///  * `metrics`：只记账（测量是环境事实，不是通过依据）。
  ///  * `screenshot`：写 `evidence/`，并只在**已有真实生成痕迹**时把状态转
  ///    generated——骨架页的截图不能穿透推进门。
  Future<ThreeFeedbackResult> feedback(String name, String kind, Object? payload) async {
    final dir = projectDir(name);
    final state = _readStateSync(name);
    if (state['current'] == 'done') throw ThreeFailure('already_done');
    final current = _passOf(state, state['current']);
    final pass = '${state['current']}';
    String status;

    if (kind == 'error') {
      final attempts = _asInt(current['attempts']) + 1;
      current['attempts'] = attempts;
      current['status'] = 'failed';
      current['last_error'] = _clip('$payload', 500);
      appendHistory(name, <String, dynamic>{
        'action': 'feedback',
        'pass': pass,
        'kind': 'error',
        'summary': _clip('$payload', 200),
      });
      status = 'failed';
    } else if (kind == 'metrics') {
      appendHistory(name, <String, dynamic>{
        'action': 'feedback',
        'pass': pass,
        'kind': 'metrics',
        'summary': _clip(payload == null ? '' : jsonEncode(payload), 200),
      });
      status = 'metrics-ok';
    } else if (kind == 'screenshot') {
      final evidence = _evidenceOf(current);
      final extracted = _screenshotPayload(payload);
      if (extracted.data.isEmpty) throw ThreeFailure('evidence_invalid', 'empty payload');
      // 体积上限先于解码：base64 长度换算成「上限对应的编码长度」，避免把
      // 巨串先解码进内存再拒绝。
      final maxEncoded = (threeEvidenceMaxBytes ~/ 3 + 1) * 4;
      if (extracted.data.length > maxEncoded) {
        throw ThreeFailure('evidence_too_large', '${extracted.data.length} chars');
      }
      // 文件数上限：预览页可以反复发截图，没有上限就是一个无限写入面。
      final total = _evidenceTotal(state);
      if (total >= threeEvidenceMaxFiles) {
        throw ThreeFailure('evidence_limit', '$total');
      }
      final Uint8List bytes;
      try {
        bytes = base64Decode(extracted.data);
      } catch (error) {
        throw ThreeFailure('evidence_invalid', '$error');
      }
      if (bytes.length > threeEvidenceMaxBytes) {
        throw ThreeFailure('evidence_too_large', '${bytes.length} bytes');
      }
      final evidenceDir = Directory('${dir.path}/evidence')..createSync(recursive: true);
      final index = evidence.length + 1;
      final fileName =
          '$pass-${extracted.tag.isEmpty ? 'shot' : extracted.tag}-${index.toString().padLeft(2, '0')}.png';
      File('${evidenceDir.path}/$fileName').writeAsBytesSync(bytes, flush: true);
      evidence.add(fileName);
      current['evidence'] = evidence;
      if (_asInt(current['attempts']) > 0 || File('${dir.path}/scene.js').existsSync()) {
        current['status'] = 'generated';
      }
      appendHistory(name, <String, dynamic>{
        'action': 'evidence',
        'pass': pass,
        'kind': 'screenshot',
        'file': fileName,
        'tag': extracted.tag,
      });
      status = 'evidence-ok';
    } else {
      throw ThreeFailure('invalid_feedback_kind', kind);
    }

    final loopMax = _asInt(state['loop_max'], threeLoopMax);
    if (kind == 'error' && _asInt(current['attempts']) >= loopMax) {
      current['status'] = 'blocked';
      state['blocked'] = true;
      state['blocked_reason'] =
          '$pass 连续 ${current['attempts']} 轮执行失败：${_clip('$payload', 200)}'
          '——保留证据，先调整规范再继续';
      appendHistory(name, <String, dynamic>{
        'action': 'blocked',
        'pass': pass,
        'summary': state['blocked_reason'],
      });
      status = 'blocked';
    }
    _writeState(name, state);
    return ThreeFeedbackResult(
      status: status,
      pass: pass,
      attempts: _asInt(current['attempts']),
      state: state,
    );
  }

  /// 评审通过：推进到下一层；最后一层通过即完成。
  ///
  /// 门禁：当前层必须是「已生成/已通过」且**有证据**（每步必带证据）。
  Future<ThreeContinueResult> continuePass(String name, [String summary = '']) async {
    final state = _readStateSync(name);
    if (state['current'] == 'done') throw ThreeFailure('already_done');
    final current = _passOf(state, state['current']);
    final pass = '${state['current']}';
    final evidence = _evidenceOf(current);
    final status = '${current['status'] ?? ''}';
    if ((status != 'generated' && status != 'verified') || evidence.isEmpty) {
      throw ThreeFailure('cannot_continue', '$pass/$status');
    }
    current['status'] = 'verified';
    appendHistory(name, <String, dynamic>{
      'action': 'continue',
      'pass': pass,
      'summary': _clip(summary, 200),
    });
    final index = (state['passes'] as List).indexWhere((p) => p is Map && p['id'] == pass);
    if (index >= 0 && index + 1 < (state['passes'] as List).length) {
      state['current'] = '${(state['passes'] as List)[index + 1]['id']}';
      _writeState(name, state);
      return ThreeContinueResult(current: '${state['current']}', done: false);
    }
    state['current'] = 'done';
    _writeState(name, state);
    appendHistory(name, <String, dynamic>{
      'action': 'done',
      'pass': '-',
      'summary': '全部层已通过',
    });
    return const ThreeContinueResult(current: 'done', done: true);
  }

  /// 规范手编回灌（手改必须落规范，不许只改代码）。
  ///
  /// 成功保存顺带解除阻塞：把标记为 blocked 的层复位成待生成、修复轮清零
  /// ——携带新规范从该层重跑；旧计数不清零会在下一次生成后立刻再次撞上限。
  Future<ThreeSpecSaveResult> saveSpec(String name, Map<String, dynamic> spec) async {
    final dir = projectDir(name);
    if (!File('${dir.path}/build-state.json').existsSync()) {
      throw ThreeFailure('no_project', name);
    }
    if (!_hasNonEmptyList(spec['components']) || !_hasNonEmptyList(spec['acceptance'])) {
      throw ThreeFailure('spec_invalid', 'components/acceptance');
    }
    _atomicWrite(File('${dir.path}/three-spec.json'), _prettyJson(spec));
    final state = _readStateSync(name);
    final wasBlocked = state['blocked'] == true;
    if (wasBlocked) {
      state['blocked'] = false;
      state['blocked_reason'] = '';
      final passes = (state['passes'] as List).whereType<Map>().toList();
      var reset = passes.where((p) => p['status'] == 'blocked').toList();
      if (reset.isEmpty) {
        final current = _passOrNull(state, state['current']);
        if (current != null) reset = <Map>[current];
      }
      for (final pass in reset) {
        pass['attempts'] = 0;
        pass['status'] = 'pending';
      }
      _writeState(name, state);
    }
    appendHistory(name, <String, dynamic>{
      'action': 'refine-spec',
      'pass': '-',
      'unblocked': wasBlocked,
      'summary': _clip('${spec['title'] ?? spec['summary'] ?? ''}', 120),
    });
    return ThreeSpecSaveResult(unblocked: wasBlocked, state: state);
  }

  /// 删除整个项目目录（名称白名单 + 只允许根下一层）。
  Future<void> deleteProject(String name) async {
    final dir = projectDir(name);
    if (dir.parent.path != _root.path) {
      throw ThreeFailure('invalid_name', 'ref');
    }
    if (!dir.existsSync()) throw ThreeFailure('no_project', name);
    dir.deleteSync(recursive: true);
  }

  // -- 预览 ----------------------------------------------------------------

  /// 把预览三件套落到项目目录（同目录，WebKit 的读取范围就是父目录）。
  ///
  /// 每次挂载都会重写宿主页（`?v=` 用当前时间戳，改完代码重新加载不命中
  /// 模块缓存）；渲染库按字节长度比对，缺失/被裁剪时从资源重拷。
  Future<ThreePreviewBundle> preparePreview(String name, {bool force = false}) async {
    final dir = projectDir(name);
    if (!File('${dir.path}/three-spec.json').existsSync()) {
      throw ThreeFailure('no_project', name);
    }
    final scene = File('${dir.path}/scene.js');
    if (!scene.existsSync()) _atomicWrite(scene, threeSceneSkeleton);

    final Uint8List templateBytes;
    final Uint8List moduleBytes;
    final Uint8List? liveBytes;
    try {
      templateBytes = await _assets(threePreviewAssetKey);
      moduleBytes = await _assets(threeModuleAssetKey);
      // 只有模板真的要沙箱执行面时才要求 three-live 在场：测试与旧模板
      // 不带该占位时不该被迫提供 225KB 资源（缺了仍由组装器显性失败）。
      final needsLive = utf8.decode(templateBytes).contains('/*__THREE_LIVE__*/');
      liveBytes = needsLive ? await _assets(threeLiveAssetKey) : null;
    } on ThreeFailure {
      rethrow;
    } catch (error) {
      throw ThreeFailure('asset_missing', '$error');
    }
    if (moduleBytes.length != threeModuleByteLength) {
      throw ThreeFailure(
        'asset_missing',
        'three.module.js: ${moduleBytes.length} != $threeModuleByteLength',
      );
    }

    final html = File('${dir.path}/preview.html');
    final sceneSource = scene.readAsStringSync();
    final rendered = assembleThreePreview(
      template: utf8.decode(templateBytes),
      threeSource: utf8.decode(moduleBytes),
      threeLiveSource: liveBytes == null ? '' : utf8.decode(liveBytes),
      sceneSource: sceneSource,
      version: DateTime.now().millisecondsSinceEpoch,
    );
    if (force || !html.existsSync() || html.readAsStringSync() != rendered) {
      _atomicWrite(html, rendered);
    }

    final module = File('${dir.path}/three.module.js');
    if (force || !module.existsSync() || module.lengthSync() != moduleBytes.length) {
      module.writeAsBytesSync(moduleBytes, flush: true);
    }

    return ThreePreviewBundle(
      htmlPath: html.path,
      scenePath: scene.path,
      modulePath: module.path,
    );
  }

  // -- ThreeUI 画廊 --------------------------------------------------------

  /// 读取并解析 vendored ThreeUI 组件清单（应用资源，离线，不联网）。
  ///
  /// 失败时抛 [ThreeFailure]：界面据此显示「组件清单没读出来」，而不是
  /// 静默给一个空画廊。
  Future<List<ThreeUiComponent>> loadUiCatalog() async {
    final Uint8List bytes;
    try {
      bytes = await _assets(threeUiCatalogAssetKey);
    } on ThreeFailure {
      rethrow;
    } catch (error) {
      throw ThreeFailure('asset_missing', '$error');
    }
    return parseThreeUiCatalog(utf8.decode(bytes));
  }

  // -- 内部：提示词 ---------------------------------------------------------

  static const String _specSystemPrompt =
      '你是 3D 场景规格师。根据 brief 产出 three-spec.json——它是后续分 pass'
      ' 生成 three.js 代码的唯一依据（spec 先行）。只输出 JSON。'
      '字段：title（短名）、summary（一句话）、components[]（每个可辨识组件：'
      '{id, what, geometry 提示, material 提示, size_scale 相对尺寸}）、'
      'materials[]（{id, color_hex, roughness, metalness}）、camera（{view 描述}）、'
      'interactions[]（动画/交互清单）、acceptance[]（验收标准，可判真伪，3-6 条）、'
      'complexity（simple|moderate|complex）。';

  static const String _passSystemPrompt =
      '你是 three.js 场景工程师（分 pass 雕塑纪律）。契约：\n'
      '1. scene.js 必须默认导出 `export default function build(THREE, scene, camera, controls, renderer)`；'
      '**不要写任何 import 语句**——THREE 由宿主作为第一个参数传入（file:// 预览页面不允许模块取文件）。\n'
      '2. 返回 `{ metrics: {...}, update(dt) {...} }`（可选）：metrics 进测量反馈，update 为逐帧动画。\n'
      '3. **只实现/完善当前 pass 的层**，其余层保持已有代码不退化（重写整文件，但不得删除其他层的成果）。\n'
      '4. 所有反馈（错误/测量）都已修完才可能收到本任务；blocked 时先改 spec 不写代码。\n'
      '5. 只输出完整 scene.js 代码（```js 围栏或裸码，必须含 export default）。';

  ({String system, String prompt}) _passPrompt(String name) {
    final spec = _readSpecSync(name);
    final state = _readStateSync(name);
    final current = _passOf(state, state['current']);
    final pass = '${state['current']}';
    final goal = threePassGoal(pass);
    final sceneFile = File('${projectDir(name).path}/scene.js');
    final existing = sceneFile.existsSync() ? sceneFile.readAsStringSync() : '';
    final prompt = StringBuffer()
      ..writeln('# 规格（three-spec.json）')
      ..writeln(_prettyJson(spec))
      ..writeln()
      ..writeln('# 当前 pass：$pass —— $goal')
      ..writeln('# 修复轮：${_asInt(current['attempts'])}/${_asInt(state['loop_max'], threeLoopMax)}'
          '（本 pass 已失败 ${_asInt(current['attempts'])} 次；若有失败原因见下方反馈记录）');
    if (existing.isNotEmpty) {
      prompt
        ..writeln('# 当前 scene.js（在此基础上完善，勿退化其他层）')
        ..writeln('```js')
        ..writeln(existing)
        ..writeln('```');
    } else {
      prompt.writeln('# 尚无代码——从本 pass 起步。');
    }
    prompt.writeln();
    prompt.writeln('请输出本 pass（$pass）完成后的完整 scene.js。');
    return (system: _passSystemPrompt, prompt: prompt.toString());
  }

  // -- 内部：模型与解析 -----------------------------------------------------

  Future<String> _chat({
    required String system,
    required String prompt,
    required ThreeLlmConfig config,
  }) async {
    if (!config.isConfigured) throw ThreeFailure('llm_error', 'missing credentials');
    return _llm(ThreeLlmRequest(
      system: system,
      prompt: prompt,
      model: config.model,
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      thinkingLevel: config.thinkingLevel,
    ));
  }

  /// 从回复里取 JSON：```json 围栏优先，其次裸 JSON 的花括号区间。
  Map<String, dynamic> _extractJson(String raw) {
    var text = raw.trim();
    if (text.contains('```')) {
      for (var segment in text.split('```')) {
        segment = segment.trim();
        if (segment.startsWith('json')) segment = segment.substring(4).trim();
        if (segment.trimLeft().startsWith('{')) {
          text = segment.trim();
          break;
        }
      }
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) throw ThreeFailure('spec_parse_failed', 'no json object');
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is! Map) throw const FormatException('not an object');
      return decoded.cast<String, dynamic>();
    } catch (error) {
      throw ThreeFailure(
        'spec_parse_failed',
        '$error: ${_clip(text.substring(start, end + 1), 120)}',
      );
    }
  }

  /// 从回复里取场景代码：```js 围栏优先，其次裸码；必须含默认导出。
  String _extractJs(String raw) {
    if (raw.contains('```')) {
      for (var segment in raw.split('```')) {
        segment = segment.trim();
        if (segment.startsWith('js') ||
            segment.startsWith('javascript') ||
            segment.startsWith('module')) {
          final newline = segment.indexOf('\n');
          segment = newline >= 0 ? segment.substring(newline + 1) : segment;
        }
        if (segment.contains('export default')) return '${segment.trim()}\n';
      }
    }
    if (raw.contains('export default')) return '${raw.trim()}\n';
    throw ThreeFailure('code_parse_failed', 'no export default');
  }

  // -- 内部：磁盘 -----------------------------------------------------------

  Map<String, dynamic> _readSpecSync(String name) {
    final file = File('${projectDir(name).path}/three-spec.json');
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.cast<String, dynamic>();
    } catch (error) {
      throw ThreeFailure('spec_corrupt', '$error');
    }
  }

  /// 读进度；坏档（半截 JSON / 形状不对）备份 `.bak` 后重置为初始进度。
  Map<String, dynamic> _readStateSync(String name) {
    final file = File('${projectDir(name).path}/build-state.json');
    if (!file.existsSync()) throw ThreeFailure('no_project', name);
    Map<String, dynamic>? state;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map && decoded['passes'] is List) {
        state = decoded.cast<String, dynamic>();
      }
    } catch (_) {
      state = null;
    }
    if (state != null) return state;
    try {
      file.renameSync('${file.path}.bak');
    } on FileSystemException {
      // 备份失败不阻断自愈：重置值本身就是唯一可信状态。
    }
    final reset = initialThreeState();
    _writeState(name, reset);
    appendHistory(name, <String, dynamic>{
      'action': 'state-corrupt-reset',
      'pass': '-',
      'summary': '进度文件损坏，已备份 .bak 并重置为初始 pass',
    });
    return reset;
  }

  void _writeState(String name, Map<String, dynamic> state) {
    _atomicWrite(
      File('${projectDir(name).path}/build-state.json'),
      const JsonEncoder.withIndent(' ').convert(state),
    );
  }

  /// 同目录临时文件 + flush + 原子替换；替换失败（Windows 目标在场）时先删
  /// 再改名。进度文件自称权威，绝不能写出半截 JSON。
  void _atomicWrite(File file, String text) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    final handle = tmp.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeStringSync(text);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    try {
      tmp.renameSync(file.path);
    } on FileSystemException {
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(file.path);
    }
  }

  List<Map<String, dynamic>> _readHistory(String name) {
    final file = File('${projectDir(name).path}/history.jsonl');
    if (!file.existsSync()) return const <Map<String, dynamic>>[];
    final lines = file.readAsStringSync().split('\n').where((l) => l.trim().isNotEmpty).toList();
    final tail = lines.length > 50 ? lines.sublist(lines.length - 50) : lines;
    final out = <Map<String, dynamic>>[];
    for (final line in tail) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) out.add(decoded.cast<String, dynamic>());
      } catch (_) {
        // 崩溃时 append 可能留下半行：跳过它，不让整个项目读不出来。
      }
    }
    return out;
  }

  /// 记一笔账（JSONL 追加）。
  void appendHistory(String name, Map<String, dynamic> entry) {
    final file = File('${projectDir(name).path}/history.jsonl');
    file.parent.createSync(recursive: true);
    final line = jsonEncode(<String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch / 1000.0,
      ...entry,
    });
    file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  // -- 内部：小工具 ---------------------------------------------------------

  Map<String, dynamic> _passOf(Map<String, dynamic> state, Object? id) {
    final pass = _passOrNull(state, id);
    if (pass == null) throw ThreeFailure('state_corrupt', 'current=$id');
    return pass;
  }

  Map<String, dynamic>? _passOrNull(Map<String, dynamic> state, Object? id) {
    final passes = state['passes'];
    if (passes is! List) return null;
    for (final pass in passes) {
      if (pass is Map && pass['id'] == id) return pass.cast<String, dynamic>();
    }
    return null;
  }

  List<String> _evidenceOf(Map<String, dynamic> pass) {
    final raw = pass['evidence'];
    if (raw is List) return raw.map((e) => '$e').toList();
    final fresh = <String>[];
    pass['evidence'] = fresh;
    return fresh;
  }

  /// 项目内已落盘的证据文件数（按进度文件记账，不额外扫目录）。
  int _evidenceTotal(Map<String, dynamic> state) {
    var total = 0;
    for (final pass in (state['passes'] as List? ?? const [])) {
      if (pass is Map && pass['evidence'] is List) {
        total += (pass['evidence'] as List).length;
      }
    }
    return total;
  }

  ({String data, String tag}) _screenshotPayload(Object? payload) {
    if (payload is Map) {
      final tag = _clip(_sanitizeTag('${payload['tag'] ?? ''}'), 24);
      final data = '${payload['data'] ?? ''}';
      return (data: _stripPngDataUrl(data), tag: tag);
    }
    return (data: _stripPngDataUrl('${payload ?? ''}'), tag: '');
  }

  String _stripPngDataUrl(String data) {
    const prefix = 'data:image/png;base64,';
    return data.startsWith(prefix) ? data.substring(prefix.length) : data;
  }

  String _sanitizeTag(String tag) => tag.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');

  bool _hasNonEmptyList(Object? value) => value is List && value.isNotEmpty;

  String _prettyJson(Object? value) => const JsonEncoder.withIndent(' ').convert(value);

  String _clip(String text, int max) => text.length <= max ? text : text.substring(0, max);

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }
}

// ---------------------------------------------------------------------------
// 预览页面组装（自包含，file:// 可用）
// ---------------------------------------------------------------------------

/// 渲染库源码 → 同一模块作用域里的 `THREE` 命名空间对象。
///
/// r160 的 `three.module.js` 只有**一条**收尾的 `export { A, B, ... };`，没有
/// import。把这条出口语句改写成 `const THREE = { A, B, ... };` 之后，整份源码
/// 就是一个合法的内联模块：既保留了内部作用域，又把全部 416 个出口聚成一个
/// 可直接传给场景的对象——不需要 importmap，也不需要取第二个文件。
String threeModuleAsInlineNamespace(String source) {
  final matches = RegExp(r'export\s*\{([\s\S]*?)\}\s*;?\s*$').allMatches(source).toList();
  if (matches.isEmpty) {
    throw ThreeFailure('asset_missing', 'three.module.js: no export block at the end');
  }
  final block = matches.last;
  final names = block
      .group(1)!
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();
  if (names.isEmpty) {
    throw ThreeFailure('asset_missing', 'three.module.js: empty export block');
  }
  final entries = <String>[];
  for (final name in names) {
    final alias = name.split(RegExp(r'\s+as\s+'));
    entries.add(alias.length == 2 ? '${alias[1].trim()}: ${alias[0].trim()}' : name);
  }
  final replacement = 'const THREE = {\n${entries.map((e) => '  $e,').join('\n')}\n};\n';
  return source.replaceRange(block.start, block.end, replacement);
}

/// 场景源码 → 同一模块作用域里可直接调用的构建函数。
///
/// 允许的形态：`export default function build(...)`、`export default async
/// function build(...)`、`export default (…) => …`、`export default 标识符`。
/// import 语句会被剥掉（渲染库已在同一作用域，不需要也不允许再取模块）；
/// 剥不干净或还有别的 export 就显性失败——宁可让用户看到一句人话，也不生成
/// 一个必然白屏的页面。
({String source, String entry}) threeSceneAsInlineFunction(String source) {
  var code = source.replaceAll(RegExp(r'(^|\n)\s*import\s+[^;]*;'), '\n');
  if (RegExp(r'(^|\n)\s*import\b').hasMatch(code)) {
    throw ThreeFailure('code_parse_failed', 'scene.js still contains an import statement');
  }
  if (RegExp(r'export\s+default\s+class').hasMatch(code)) {
    throw ThreeFailure('code_parse_failed', 'scene.js exports a class, not a build function');
  }
  final named = RegExp(r'export\s+default\s+(async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)')
      .firstMatch(code);
  String entry;
  if (named != null) {
    entry = named.group(2)!;
    code = code.replaceFirst(RegExp(r'export\s+default\s+'), '');
  } else if (RegExp(r'export\s+default\b').hasMatch(code)) {
    entry = '__build';
    code = code.replaceFirst(RegExp(r'export\s+default\s+'), 'const __build = ');
  } else {
    throw ThreeFailure('code_parse_failed', 'scene.js has no export default');
  }
  if (RegExp(r'(^|\n)\s*export\b').hasMatch(code)) {
    throw ThreeFailure('code_parse_failed', 'scene.js has other export statements');
  }
  return (source: code, entry: entry);
}

/// 离线预览页的严格 CSP（与热应用、连接桌面的资源页同一道门）。
///
/// file:// 页没有响应头，只能经 `<meta http-equiv>` 生效，且必须早于页面上的
/// 第一个脚本。场景代码由模型生成，属于**不可信输入**：
///  * `script-src 'unsafe-inline'`：只允许页面内联脚本（渲染库与场景都内联）；
///  * `script-src 'unsafe-eval'` + `worker-src blob:`：three-live 的
///    `allow-client-scripts` 沙箱要把场景脚本放进 Worker 里用 `new Function`
///    编译（Worker 继承文档 CSP），Worker 自身用 blob: 创建——这是让真实
///    three-live 沙箱跑起来的最小放宽。沙箱内网络/存储/消息通道已被上游移除；
///  * `connect-src 'none'`：关闭 fetch/XHR/WebSocket/beacon 等全部外联通道；
///  * `default-src 'none'`：其余资源（远端脚本/样式/图片/字体）一律不加载；
///  * `frame-ancestors 'none'`：不允许被任何页面嵌套。
const String threePreviewCsp = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; "
    "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "connect-src 'none'; worker-src blob:; frame-ancestors 'none'";

const String _cspMetaMarker = 'http-equiv="Content-Security-Policy"';

/// 模板自带 CSP（见 assets/three/preview.html）时原样保留；缺失时在
/// DOCTYPE 之后（没有就字节 0）注入——保证策略早于第一个脚本生效。
String ensureThreePreviewCsp(String html) {
  if (html.contains(_cspMetaMarker)) return html;
  final meta = '<meta http-equiv="Content-Security-Policy" content="$threePreviewCsp">';
  final doctype = RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false).firstMatch(html);
  final index = doctype?.end ?? 0;
  return html.replaceRange(index, index, meta);
}

/// 组装自包含的预览宿主页（模板占位替换）。
///
/// 为什么内联：桌面 WKWebView 与移动端 Chromium 都禁止 `file://` 页面用
/// 模块 import / fetch 读同目录文件（实测：`Cross-origin script load denied by
/// Cross-Origin Resource Sharing policy`）。内联后页面零文件读取，file:// 直接
/// 可用；项目目录里仍并排保留三件套供核对。
String assembleThreePreview({
  required String template,
  required String threeSource,
  required String sceneSource,
  required int version,
  String threeLiveSource = '',
}) {
  const threeSlot = '/*__THREE_MODULE__*/';
  const sceneSlot = '/*__SCENE_SOURCE__*/';
  const liveSlot = '/*__THREE_LIVE__*/';
  const sandboxSlot = '/*__SCENE_SANDBOX__*/';
  if (!template.contains(threeSlot) || !template.contains(sceneSlot)) {
    throw ThreeFailure('asset_missing', 'preview.html: inline placeholders missing');
  }
  // 占位必须**恰好出现一次**：模板注释里再写一遍占位会把注入点顶到注释里，
  // 生成一个白屏页面（实测事故）。宁可显性失败。
  if (threeSlot.allMatches(template).length != 1) {
    throw ThreeFailure('asset_missing', 'preview.html: THREE placeholder must appear exactly once');
  }
  if (sceneSlot.allMatches(template).length != 1) {
    throw ThreeFailure('asset_missing', 'preview.html: scene placeholder must appear exactly once');
  }
  final hasLive = template.contains(liveSlot);
  final hasSandbox = template.contains(sandboxSlot);
  if (hasLive && liveSlot.allMatches(template).length != 1) {
    throw ThreeFailure('asset_missing', 'preview.html: three-live placeholder must appear exactly once');
  }
  if (hasSandbox && sandboxSlot.allMatches(template).length != 1) {
    throw ThreeFailure('asset_missing', 'preview.html: sandbox placeholder must appear exactly once');
  }
  if (hasLive && threeLiveSource.isEmpty) {
    // 模板要求沙箱执行面，却没拿到 three-live 源码：显性失败，不产出
    // 「占位没被替换」的半成品页面（那会白屏）。
    throw ThreeFailure('asset_missing', 'preview.html: three-live source missing');
  }
  final namespace = threeModuleAsInlineNamespace(threeSource);
  final scene = threeSceneAsInlineFunction(sceneSource);
  final callable = '${scene.source}\n'
      'const __non3d_scene_build__ = ${scene.entry};\n'
      '// build $version\n';
  var injected = template.replaceFirst(threeSlot, namespace).replaceFirst(sceneSlot, callable);
  if (hasLive) injected = injected.replaceFirst(liveSlot, threeLiveSource);
  if (hasSandbox) injected = injected.replaceFirst(sandboxSlot, callable);
  if (injected.contains(threeSlot) ||
      injected.contains(sceneSlot) ||
      (hasLive && injected.contains(liveSlot)) ||
      (hasSandbox && injected.contains(sandboxSlot))) {
    throw ThreeFailure('asset_missing', 'preview.html: placeholders left after assembly');
  }
  // CSP 是预览页的第二道防线（第一道是内容自包含）：模板没带就补上，
  // 保证任何组装路径产出的页面都零外联。
  return ensureThreePreviewCsp(injected);
}

// ---------------------------------------------------------------------------
// 文件夹定位（走平台能力，不自己嗅探）
// ---------------------------------------------------------------------------

/// 在系统文件管理器里定位 [path]。
///
/// 只做平台矩阵允许的事：[host] 不支持（手机/平板）或目录不在时返回 false，
/// 调用方据此隐藏入口——不在移动端假装成功。
Future<bool> revealThreeProject(String path, {required PlatformCapabilities host}) async {
  if (path.isEmpty || !host.supportsRevealInFolder) return false;
  if (!Directory(path).existsSync()) return false;
  try {
    if (host.os == HostOs.macos) {
      await Process.run('open', <String>['-R', path]);
    } else if (host.os == HostOs.windows) {
      // explorer 命中成功也常返回非 0，不看退出码。
      await Process.run('explorer', <String>['/select,$path']);
    } else {
      await Process.run('xdg-open', <String>[path]);
    }
    return true;
  } catch (_) {
    return false;
  }
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}
