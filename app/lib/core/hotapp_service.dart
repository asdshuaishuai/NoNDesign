/// 热应用的本地面（批次 07）：生成 / 精修 / 列表 / 删除全部在客户端完成。
///
/// 过去这三件事都由外部服务代劳；现在只有一条模型调用（`ai_sdk` 直连当前
/// 选择的服务商），其余步骤都是本机文件与 SQLite：
///
///   一句话 → 模型产出**单个自包含 HTML**（零外链、无网络请求）→
///   离线门校验 → 落本地库（`nonapp_library.dart`）→ WebView 预览即运行时。
///
/// 质量与安全边界（fail-closed）：
///  * 模型输出先剥代码围栏，再跑 [assertHtmlOfflineSafe]——外链、缺失结构、
///    过短文档一律拒，**不落半成品**；
///  * 精修失败保留旧版本（覆盖是最后一步的原子 rename）；
///  * 导入的包与生成的包走同一条库路径，导出时再打回 `.nonapp`。
///
/// 这里不拼用户可见文案：失败以 [HotAppFailure.code] 表达，界面经
/// [hotAppFailureMessage] 翻成一句人话，原始诊断只进日志/技术详情。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_sdk_dart/ai_sdk_dart.dart' show TimeoutConfiguration, generateText;
import 'package:ai_sdk_openai/ai_sdk_openai.dart' show OpenAIProvider;

import 'hotapp_db.dart';
import 'nonapp_library.dart';
import 'nonapp_package.dart';

/// 生成名规则：目录名、清单 id、导出包名三处共用（小写 ASCII）。
final RegExp _hotAppNameRe = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

/// 生成一次 HTML 的模型调用上限（与另外两个工作台同量级）。
const Duration hotAppLlmTimeout = Duration(minutes: 3);

/// 一次生成/精修的模型入参。
class HotAppLlmRequest {
  const HotAppLlmRequest({
    required this.system,
    required this.prompt,
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    this.thinkingLevel = 'auto',
    this.temperature = 0.6,
  });

  final String system;
  final String prompt;
  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;
  final double temperature;
}

/// 模型调用签名（测试注入假实现，不碰网络）。
typedef HotAppLlmCall = Future<String> Function(HotAppLlmRequest request);

/// 当前选中的模型连接参数。
class HotAppLlmConfig {
  const HotAppLlmConfig({
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    this.thinkingLevel = 'auto',
  });

  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;

  bool get isConfigured => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

/// 热应用失败（内部代号；界面经 [hotAppFailureMessage] 翻译）。
class HotAppFailure implements Exception {
  const HotAppFailure(this.code, [this.detail = '']);

  /// 内部代号，只进日志与技术详情。
  final String code;

  /// 原始诊断（模型回包片段、文件异常等），永不上屏。
  final String detail;

  @override
  String toString() => detail.isEmpty ? code : '$code: $detail';
}

/// 失败码 → 用户可见句子（术语表 §4：不出现实现名与裸错误码）。
String hotAppFailureMessage(HotAppFailure? failure) {
  switch (failure?.code) {
    case 'brief_empty':
      return '先写一句想要的动画或玩法';
    case 'name_invalid':
      return '应用名只能用字母、数字、短横线和下划线';
    case 'name_taken':
      return '已经有同名应用了，换一个名字';
    case 'html_invalid':
      return '这一次没有生成出可用的页面，请重试';
    case 'html_external_refs':
      return '生成的内容引用了网络资源，已拒绝保存';
    case 'no_app':
      return '这个应用已经不在了';
    case 'llm_error':
      return '模型这次没有响应，请稍后重试';
    case 'store_error':
      return '应用没能保存到本机，请检查磁盘空间';
    default:
      return '这次操作没有完成，请重试';
  }
}

/// 热应用本地面。
class HotAppService {
  HotAppService({required this.library, HotAppLlmCall? llm})
      : _llm = llm ?? defaultHotAppLlmCall;

  final NonAppLibrary library;
  final HotAppLlmCall _llm;

  /// 打开默认库（`<projectsRoot>/hotapps`）；[root] 供测试注入临时目录。
  static Future<HotAppService> open({Directory? root, HotAppLlmCall? llm}) async {
    final lib = await NonAppLibrary.open(root: root);
    return HotAppService(library: lib, llm: llm);
  }

  /// 全部应用（作品集/应用列表同源）。
  Future<List<LibraryApp>> list() => library.scan();

  Future<LibraryApp?> read(String name) => library.read(name);

  Future<String?> html(String name) => library.readHtml(name);

  Future<List<Object?>?> surface(String name) => library.readSurface(name);

  Future<List<int>> exportPackage(String name) => library.buildPackage(name);

  Future<void> delete(String name) => library.delete(name);

  HotAppDb openDb(String name) => library.openDb(name);

  /// 生成一个新应用。
  ///
  /// 任何失败（模型、校验、落盘）都不留半成品；同名应用存在时直接拒绝，
  /// 不静默覆盖用户的旧数据。
  Future<LibraryApp> generate({
    required String name,
    required String brief,
    required HotAppLlmConfig config,
  }) async {
    final cleanName = name.trim();
    final cleanBrief = brief.trim();
    if (cleanBrief.isEmpty) throw const HotAppFailure('brief_empty');
    if (!_hotAppNameRe.hasMatch(cleanName)) throw const HotAppFailure('name_invalid');
    if (!config.isConfigured) throw const HotAppFailure('llm_error', 'model_not_configured');
    if (await library.read(cleanName) != null) throw const HotAppFailure('name_taken');

    final raw = await _chat(
      HotAppLlmRequest(
        system: _hotAppSystemPrompt,
        prompt: '应用名：$cleanName\n需求：$cleanBrief',
        model: config.model,
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        thinkingLevel: config.thinkingLevel,
      ),
    );
    final html = normalizeHotAppHtml(raw, brief: cleanBrief);
    return _install(name: cleanName, title: cleanBrief, html: html, brief: cleanBrief);
  }

  /// 「由原型生成可验证的热应用」。
  ///
  /// 与 [generate] 的区别：需求不是一句话，而是原型本身——画板清单 + 跳转
  /// 清单 + 规范文档。生成后跑**确定性覆盖验证**：
  ///  * 每个画板必须有 `<section data-screen="<id>">`；
  ///  * 每条跳转 from→to 必须在 from 画板段落里出现 `data-nav="<to>"`。
  /// 结构门（离线 / 零外链 / CSP）仍由 NonAppLibrary.install 把关。
  /// 验证失败不回滚安装，但结果如实标注未通过项。
  Future<HotAppFromPrototypeResult> generateFromPrototype({
    required String name,
    required HotAppLlmConfig config,
    required String prototypeMbt,
    required List<PrototypeScreenSpec> screens,
    required List<PrototypeLinkSpec> flows,
  }) async {
    final cleanName = name.trim();
    if (screens.isEmpty) throw const HotAppFailure('brief_empty', 'prototype_has_no_screens');
    if (!config.isConfigured) throw const HotAppFailure('llm_error', 'model_not_configured');
    if (!_hotAppNameRe.hasMatch(cleanName)) throw const HotAppFailure('name_invalid');
    if (await library.read(cleanName) != null) throw const HotAppFailure('name_taken');

    final screenLines = screens
        .map((s) => '- <section data-screen="${s.id}"> …标题：${s.title.isEmpty ? s.id : s.title}')
        .join('\n');
    final flowLines = flows.isEmpty
        ? '（原型没有声明跳转）'
        : flows.map((f) => "- ${f.from} → ${f.to}（在 ${f.from} 段落内的可点元素上加 data-nav=\"${f.to}\"）").join('\n');
    final doc = prototypeMbt.trim().isEmpty ? '（无）' : prototypeMbt.trim();

    final prompt = '把下面的产品原型忠实实现为单文件 HTML 应用。\n'
        '硬性要求（缺一条都算没有完成）：\n'
        '1. 每个原型画板对应一个段落：<section data-screen=\"画板id\">…</section>；'
        '页面初始只显示入口画板，其余隐藏。\n'
        '2. 每条原型跳转 from→to：在 from 画板段落内的可点元素上加属性 '
        'data-nav=\"to\",点击后切换到目标画板。\n'
        '3. 需要记住的数据一律用 window.NoN.db.exec（本机 SQLite，无需服务器）。\n'
        '4. 不引用任何网络资源：CSS/JS 全内联，不出现 http(s):// 或 // 开头的外链。\n'
        '5. 只输出完整 HTML 文档，不要解释。\n\n'
        '原型画板：\n$screenLines\n\n原型跳转：\n$flowLines\n\n'
        '原型规范文档（供理解语义）：\n$doc';

    final raw = await _chat(
      HotAppLlmRequest(
        system: _hotAppSystemPrompt,
        prompt: prompt,
        model: config.model,
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        thinkingLevel: config.thinkingLevel,
      ),
    );
    final brief = '原型生成（${screens.length} 屏 / ${flows.length} 条跳转）';
    final htmlBytes = normalizeHotAppHtml(raw, brief: brief);
    final html = utf8.decode(htmlBytes);
    final app = await _install(name: cleanName, title: brief, html: htmlBytes, brief: brief);
    final checks = _verifyPrototypeCoverage(html, screens, flows);
    return HotAppFromPrototypeResult(
      app: app,
      checks: checks,
      verified: checks.every((c) => c.ok),
    );
  }

  /// 精修现有应用（覆盖即热更新）。
  ///
  /// 失败时旧文件原样保留（校验通过才写临时文件，最后一步 rename 替换）。
  Future<LibraryApp> refine({
    required String name,
    required String instruction,
    required HotAppLlmConfig config,
  }) async {
    final cleanInstruction = instruction.trim();
    if (cleanInstruction.isEmpty) {
      throw const HotAppFailure('brief_empty');
    }
    if (!config.isConfigured) throw const HotAppFailure('llm_error', 'model_not_configured');
    final existing = await library.read(name);
    if (existing == null) throw HotAppFailure('no_app', name);
    if (existing.isA2ui) throw const HotAppFailure('html_invalid', 'a2ui_payload_not_editable');
    final current = await library.readHtml(name);
    if (current == null) throw HotAppFailure('no_app', name);

    final raw = await _chat(
      HotAppLlmRequest(
        system: _hotAppRefinePrompt,
        prompt: '当前页面（完整源码）：\n```html\n$current\n```\n\n修改要求：$cleanInstruction',
        model: config.model,
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        thinkingLevel: config.thinkingLevel,
        temperature: 0.4,
      ),
    );
    final html = normalizeHotAppHtml(raw, brief: instruction, requireDocument: true);
    // 精修必须保留 manifest（标题/创建时间/数据都不动），只替换页面。
    final manifest = await library.read(name);
    if (manifest == null) throw HotAppFailure('no_app', name);
    try {
      return await library.replaceHtml(name, html);
    } on NonAppException catch (error) {
      throw _storeFailure(error);
    } on FileSystemException catch (error) {
      throw HotAppFailure('store_error', '$error');
    }
  }

  HotAppFailure _storeFailure(NonAppException error) {
    if (error.code.startsWith('nonapp_html_external_refs')) {
      return HotAppFailure('html_external_refs', error.code);
    }
    if (error.code.startsWith('nonapp_html_invalid')) {
      return HotAppFailure('html_invalid', error.code);
    }
    return HotAppFailure('store_error', error.code);
  }

  Future<LibraryApp> _install({
    required String name,
    required String title,
    required Uint8List html,
    String? brief,
    int? createdAt,
  }) async {
    final pkg = NonAppPackage(
      manifest: NonAppManifest(
        formatVersion: nonAppFormatVersion,
        id: name,
        name: name,
        title: title.isEmpty ? name : title,
        renderer: 'html',
        createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        minAppVersion: nonAppClientVersion,
        brief: brief,
      ),
      htmlBytes: html,
    );
    try {
      return await library.install(pkg);
    } on NonAppException catch (error) {
      throw _storeFailure(error);
    } on FileSystemException catch (error) {
      throw HotAppFailure('store_error', '$error');
    }
  }

  Future<String> _chat(HotAppLlmRequest request) async {
    try {
      return await _llm(request);
    } on HotAppFailure {
      rethrow;
    } catch (error) {
      throw HotAppFailure('llm_error', '$error');
    }
  }
}

/// 默认模型调用：`ai_sdk` 单轮补全，OpenAI 兼容协议。
Future<String> defaultHotAppLlmCall(HotAppLlmRequest request) async {
  final provider = OpenAIProvider(apiKey: request.apiKey, baseUrl: request.baseUrl);
  try {
    final result = await generateText<Object?>(
      model: provider.call(request.model.isEmpty ? 'gpt-5.1' : request.model),
      system: request.system,
      prompt: request.prompt,
      temperature: request.temperature,
      providerOptions: hotAppProviderOptions(request.thinkingLevel),
      timeout: const TimeoutConfiguration(total: hotAppLlmTimeout),
    );
    return result.text;
  } catch (error) {
    throw HotAppFailure('llm_error', '$error');
  } finally {
    provider.dispose();
  }
}

/// 思考等级 → `reasoning_effort`（只认 low/medium/high，其余不注入）。
String? hotAppReasoningEffort(String level) {
  if (level == 'low' || level == 'medium' || level == 'high') return level;
  return null;
}

/// `ai_sdk` 的 providerOptions 形状（null = 不注入）。
Map<String, Map<String, dynamic>>? hotAppProviderOptions(String level) {
  final effort = hotAppReasoningEffort(level);
  if (effort == null) return null;
  return <String, Map<String, dynamic>>{
    'openai': <String, dynamic>{'reasoning_effort': effort},
  };
}

/// 模型回包 → 可落盘的 HTML 字节。
///
/// 步骤：去代码围栏 → 取文档起点（首个 `<` 起） → 空白裁剪 →
/// 原型侧输入：画板与跳转（来自引擎渲染信封）。
class PrototypeScreenSpec {
  final String id;
  final String title;
  const PrototypeScreenSpec({required this.id, required this.title});
}

class PrototypeLinkSpec {
  final String from;
  final String to;
  const PrototypeLinkSpec({required this.from, required this.to});
}

/// 单条验证结论（确定性检查，不是模型自评）。
class HotAppVerifyCheck {
  final String id;
  final bool ok;
  final String detail;
  const HotAppVerifyCheck(this.id, this.ok, this.detail);
}

/// 「由原型生成热应用」的结果：应用本体 + 覆盖验证报告。
/// [verified] 为 false 时应用已入库（结构门全过），但原型覆盖不完全——
/// 调用方必须把缺失项如实告诉用户，不得冒充成功。
class HotAppFromPrototypeResult {
  final LibraryApp app;
  final List<HotAppVerifyCheck> checks;
  final bool verified;
  const HotAppFromPrototypeResult({
    required this.app,
    required this.checks,
    required this.verified,
  });

  /// 未通过检查的人话摘要（为空 = 全部通过）。
  String get failureSummary {
    final bad = checks.where((c) => !c.ok).toList();
    if (bad.isEmpty) return '';
    return bad.map((c) => c.detail).join('；');
  }
}

final RegExp _prototypeScreenTagRe = RegExp('data-screen="([a-zA-Z0-9_-]+)"');

/// 确定性覆盖验证：画板段落 + 跳转连线，全部是字节级检查。
List<HotAppVerifyCheck> _verifyPrototypeCoverage(
  String html,
  List<PrototypeScreenSpec> screens,
  List<PrototypeLinkSpec> flows,
) {
  final checks = <HotAppVerifyCheck>[];
  // 画板段落位置表：id → 在文档中的出现位置（按出现顺序切段）。
  final marks = <String, int>{};
  for (final m in _prototypeScreenTagRe.allMatches(html)) {
    final id = m.group(1)!;
    marks.putIfAbsent(id, () => m.start);
  }
  final ordered = marks.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
  int sectionEnd(int pos) {
    for (final e in ordered) {
      if (e.value > pos) return e.value;
    }
    return html.length;
  }

  for (final screen in screens) {
    final present = marks.containsKey(screen.id);
    checks.add(HotAppVerifyCheck(
      'screen_${screen.id}',
      present,
      present ? '画板 ${screen.id} 已实现' : '缺少画板 ${screen.id}（${screen.title}）',
    ));
  }
  for (final flow in flows) {
    final fromPos = marks[flow.from];
    var ok = false;
    var detail = '跳转 ${flow.from} → ${flow.to}：来源画板不存在';
    if (fromPos != null) {
      final span = html.substring(fromPos, sectionEnd(fromPos));
      ok = span.contains('data-nav="${flow.to}"');
      detail = ok
          ? '跳转 ${flow.from} → ${flow.to} 已实现'
          : '跳转 ${flow.from} → ${flow.to} 缺少连线（from 段落里没有 data-nav="${flow.to}"）';
    }
    checks.add(HotAppVerifyCheck(
      'flow_${flow.from}_${flow.to}',
      ok,
      detail,
    ));
  }
  return checks;
}

/// [assertHtmlOfflineSafe]（零外链 + 结构 + 最短长度）。
Uint8List normalizeHotAppHtml(String raw, {required String brief, bool requireDocument = true}) {
  var text = raw.trim();
  final fence = RegExp(r'```(?:html|HTML)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null && fence.group(1)!.trim().isNotEmpty) {
    text = fence.group(1)!.trim();
  }
  final start = text.indexOf('<');
  if (start > 0) text = text.substring(start);
  final end = text.lastIndexOf('</html>');
  if (end >= 0) text = text.substring(0, end + '</html>'.length);
  text = text.trim();
  if (text.isEmpty) throw const HotAppFailure('html_invalid', 'empty');
  if (requireDocument && !text.toLowerCase().contains('</html>')) {
    throw const HotAppFailure('html_invalid', 'missing_document_end');
  }
  try {
    assertHtmlOfflineSafe(text);
  } on NonAppException catch (error) {
    if (error.code.startsWith('nonapp_html_external_refs')) {
      throw HotAppFailure('html_external_refs', error.code);
    }
    throw HotAppFailure('html_invalid', error.code);
  }
  return Uint8List.fromList(utf8.encode(text));
}

// ---------------------------------------------------------------------------
// 提示词（不进文案扫描面：只给模型看）
// ---------------------------------------------------------------------------

const String _hotAppSystemPrompt = '''
You build a single self-contained HTML mini-app (a "hot app") from one sentence.

Hard rules — violating any of them makes the result unusable:
1. Output ONE complete HTML document. No markdown fences, no commentary.
2. Everything inline: CSS in <style>, JS in <script>. NO external URLs of any
   kind (no http://, https://, //cdn, no web fonts, no remote images/audio).
3. No fetch / XMLHttpRequest / WebSocket / EventSource / dynamic imports.
   The page must render and run with the network fully offline.
4. Images must be inline SVG or CSS gradients. Audio, if needed, must be
   synthesized with the Web Audio API (no files).
5. The page must be responsive and fill the viewport. Prefer canvas/SVG/CSS
   animation. Make it genuinely interactive (tap / drag / keys) when the brief
   suggests play.
6. If the app needs to remember data, use `window.NoN.db.exec({sql, params})`
   which returns a Promise of `{ok, rows, changes, last_insert_rowid}`. Create
   your own tables first (single statement per call, no semicolons inside the
   SQL, no ATTACH). Keep queries small. If it returns `{ok:false}`, degrade
   gracefully instead of blocking the UI.
7. All visible copy must match the language of the brief and sound human.
8. Keep the document under 200 KB. Skip frameworks; plain JS only.

Return only the HTML document.
''';

const String _hotAppRefinePrompt = '''
You revise an existing self-contained HTML mini-app.

Hard rules:
1. Return ONE complete HTML document (the whole file), no markdown fences.
2. Keep the existing structure and behavior unless the requested change says
   otherwise. Do not drop features silently.
3. Everything stays inline and offline: no external URLs, no fetch/XHR/
   WebSocket. CSS/SVG/JS only; inline data URIs are fine.
4. Persistence still goes through `window.NoN.db.exec({sql, params})`
   (single statements, no ATTACH). Existing tables keep working.
5. Keep the document under 200 KB. Plain JS only.

Return only the HTML document.
''';
