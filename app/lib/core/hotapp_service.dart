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
