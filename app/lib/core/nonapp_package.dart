// `.nonapp` 单文件包（文件即应用 v2）的客户端解析与校验。
//
// 容器与字段契约见 docs/plan-chat-stream-shell.md §1.1。批次 07 起服务端
// 不再参与运行时：本文件就是包契约的唯一实现（校验顺序与稳定 code 以这里
// 为准；旧的在线实现已退役，保留稳定 code 是为了旧包/旧日志仍可对照）：
//
//   manifest.json          formatVersion / id / name / title / renderer /
//                          createdAt / minAppVersion（可选 brief）
//   payload/index.html     renderer=html 的载荷（零外链）
//   payload/surface.json   renderer=a2ui 的载荷（数组或 {"messages":[...]}）
//   payload/data.json      a2ui 可选 DataModel 快照（object）
//   payload/prompt.txt     a2ui 可选续跑提示（<=8KiB，本批不消费）
//
// **识别以 manifest.json 为唯一判据**（扩展名只用于 file_selector 过滤与
// OS 关联）。业务数据（app.db / DataModel 运行时数据）不随包走：导入 =
// 全新实例。
//
// HTML 门分两层（历史兼容 + 本机安全）：
//
//   · `assertHtmlServerCompat`（parse 用）：**旧在线实现的宽容判据**，不比它
//     严——旧包（如 `<a href="https://…">`，旧正则只覆盖 script/link/img）
//     要能继续被解析，导出→再导入不断链。
//   · `assertHtmlOfflineSafe`（安装进本地库 / 写预览缓存前用）：允许比宽容
//     面更严（误拒可接受），绝不允许更松（file:// 下只有 CSP 兜底）。
//
// 漂移风险：服务端改了 hotapp_agent.py:185-227 的三条正则，要回来对
// `assertHtmlServerCompat`（同判据）与 `assertHtmlOfflineSafe`（更严面）。
//
//   服务端（server/hotapp_agent.py:185-227）：
//     _ATTR_REF_RE = <(script|link|img) ... (src|href|srcset)="...">   (re.I|re.S)
//     _CSS_URL_RE  = url( "..." | '...' | ... )
//     _CSS_IMPORT_RE = @import ( url( "..."|'...'|... ) | "..." | '...' | ... )
//     _is_external_ref(v) = v 小写以 http:// | https:// | // 开头，或以 / 开头
//     srcset 按逗号切分，每段取第一个空白前的 token 再判
//
//   离线更严面：属性面更宽（多认 iframe、video、source、a 等元素的 src/href/poster/
//   data），且额外全文扫 http(s)://；`//` 只在引用位置拒（JS 行注释里的
//   `//` 不是外链）。唯一豁免：内联 SVG 的 xmlns 声明（那是命名空间标识，
//   不是可加载引用，服务端也不拦）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 客户端版本（minAppVersion 语义化比较的基准）。
///
/// 仓库没有 package_info_plus（新依赖从严），版本号与 app/pubspec.yaml 的
/// `version:` 手工同步——漂移风险已登记在施工记录里。
const String nonAppClientVersion = '0.1.0';

/// 与 server/nonapp_agent.py 同一套上限（改一侧必须改另一侧）。
const int nonAppFormatVersion = 1;
const int nonAppMaxPackageBytes = 8 * 1024 * 1024;
const int nonAppMaxEntryBytes = 8 * 1024 * 1024;
const int nonAppMaxTotalUncompressed = 16 * 1024 * 1024;
const int nonAppMaxEntries = 32;
const int nonAppMaxPromptBytes = 8 * 1024;
const int nonAppMaxTitleChars = 120;
const int nonAppMaxBriefChars = 2000;

const Set<String> nonAppAllowedEntries = {
  'manifest.json',
  'payload/index.html',
  'payload/surface.json',
  'payload/data.json',
  'payload/prompt.txt',
};

/// 稳定的失败码（沿用 `nonapp_*` 形状，便于日志/测试对照；界面经
/// `nonAppExceptionMessage` 翻成一句人话，绝不直接显示 code）。
class NonAppException implements Exception {
  const NonAppException(this.code, this.message);

  /// 稳定 code（如 `nonapp_unsupported_version:2`、`nonapp_too_large`）。
  final String code;

  /// 人类可读说明（中文；UI 原样呈现）。
  final String message;

  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

/// manifest.json 的强类型视图（字段校验见 [NonAppPackage.parse]）。
/// 热应用类型：用户直接描述生成的可用应用。
const String nonAppOriginApp = 'app';

/// 热应用类型：由设计原型生成的验证式 demo（只验证逻辑与交互可行性）。
const String nonAppOriginPrototype = 'prototype';

class NonAppManifest {
  const NonAppManifest({
    required this.formatVersion,
    required this.id,
    required this.name,
    required this.title,
    required this.renderer,
    required this.createdAt,
    required this.minAppVersion,
    this.brief,
    this.origin = nonAppOriginApp,
  });

  final int formatVersion;
  final String id;
  final String name;
  final String title;

  /// `html` | `a2ui`。
  final String renderer;
  final int createdAt;
  final String minAppVersion;
  final String? brief;

  /// `app` = 用户直接描述生成的可用应用；`prototype` = 由设计原型生成的
  /// 验证式 demo（只验证逻辑与交互可行性）。缺失按 `app` 处理（旧包兼容）。
  final String origin;

  bool get isA2ui => renderer == 'a2ui';

  /// 是否为「原型验证」类型。
  bool get isPrototypeDemo => origin == nonAppOriginPrototype;

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'id': id,
        'name': name,
        'title': title,
        'renderer': renderer,
        'createdAt': createdAt,
        'minAppVersion': minAppVersion,
        'origin': origin,
        if (brief != null) 'brief': brief,
      };
}

/// 解析后的包载荷（html 与 a2ui 二选一；互斥字段按 renderer 为 null）。
class NonAppPackage {
  const NonAppPackage({
    required this.manifest,
    this.htmlBytes,
    this.messages,
    this.data,
    this.prompt,
  });

  final NonAppManifest manifest;

  /// renderer=html：UTF-8 编码的 index.html 原始字节（写缓存/传服务端都用它）。
  final Uint8List? htmlBytes;

  /// renderer=a2ui：已归一为数组的 A2UI 消息序列。
  final List<Object?>? messages;

  /// a2ui 可选 DataModel 快照（仅人类可读，不参与渲染）。
  final Map<String, dynamic>? data;

  /// a2ui 可选续跑提示（本批不消费，保留给后续 agent 续跑）。
  final String? prompt;

  String get renderer => manifest.renderer;

  /// 解析并校验一个 `.nonapp` 字节流。任何失败抛 [NonAppException]（先验后落，
  /// 不产生半成品缓存/目录）。
  static NonAppPackage parse(List<int> bytes, {String clientVersion = nonAppClientVersion}) {
    if (bytes.isEmpty) {
      throw const NonAppException('nonapp_empty_body', '包体为空');
    }
    if (bytes.length > nonAppMaxPackageBytes) {
      throw const NonAppException('nonapp_too_large', '包体超过 8MiB');
    }

    final Archive archive;
    try {
      // archive 4 默认吞掉解码错误返回空归档（guardDecode 严格模式关闭），
      // 坏 zip 会以「缺 manifest」而不是「不是有效 zip」呈现；throwOnError
      // 让结构错误显性抛出，映射回既有稳定码。
      archive = ZipDecoder().decodeBytes(bytes, verify: false, throwOnError: true);
    } catch (e) {
      throw NonAppException('nonapp_invalid_zip', '不是有效的 zip 包：$e');
    }

    // 条目数/解压上限先用中央目录声明的 size 预检（不解压超限包）；
    // 声明的 size 可被伪造，真实解压字节在读取时按块累计并硬限（下方
    // _readEntryContent：content 的读取面按声明大小截断，不能当安全门）。
    final files = archive.files;
    if (files.length > nonAppMaxEntries) {
      throw const NonAppException('nonapp_too_large', '条目数超过 32');
    }
    var declaredTotal = 0;
    for (final f in files) {
      if (f.size > nonAppMaxEntryBytes) {
        throw NonAppException('nonapp_too_large', '条目 ${f.name} 解压后超过 8MiB');
      }
      declaredTotal += f.size;
      if (declaredTotal > nonAppMaxTotalUncompressed) {
        throw const NonAppException('nonapp_too_large', '总解压体积超过 16MiB');
      }
    }

    final entries = <String, Uint8List>{};
    var actualTotal = 0;
    for (final f in files) {
      // 目录项可选（“无目录项亦可”）：只容忍 manifest/payload 两级。
      // 注意 archive 会把条目名的反斜杠归一为 '/'——归一后只可能落进
      // 白名单或撞未知名，不存在逃逸路径（'..' 仍显式拒绝）。
      if (!f.isFile) {
        final dir = f.name.endsWith('/') ? f.name.substring(0, f.name.length - 1) : f.name;
        if (dir == '' || dir == 'payload') continue;
        throw NonAppException('nonapp_unexpected_entry:${f.name}', '不允许的目录项');
      }
      _checkEntryName(f.name);
      if (entries.containsKey(f.name)) {
        throw NonAppException('nonapp_unexpected_entry:${f.name}', '重复条目');
      }
      final data = _readEntryContent(f);
      actualTotal += data.length;
      if (actualTotal > nonAppMaxTotalUncompressed) {
        throw const NonAppException('nonapp_too_large', '总解压体积超过 16MiB');
      }
      entries[f.name] = data;
    }

    final manifestBytes = entries['manifest.json'];
    if (manifestBytes == null) {
      throw const NonAppException('nonapp_missing_manifest', '缺少 manifest.json');
    }
    final manifest = _parseManifest(manifestBytes, clientVersion);

    if (manifest.renderer == 'html') {
      final raw = entries['payload/index.html'];
      if (raw == null) {
        throw const NonAppException(
            'nonapp_missing_payload', 'renderer=html 需要 payload/index.html');
      }
      final html = _decodeUtf8(raw, 'payload/index.html');
      // 在线导入的权威是服务端，这里只做**服务端等价**门（不比它严）；
      // 离线路径另外还有 assertHtmlOfflineSafe（更严），见 nonapp_cache。
      assertHtmlServerCompat(html);
      return NonAppPackage(manifest: manifest, htmlBytes: raw);
    }

    final surfaceRaw = entries['payload/surface.json'];
    if (surfaceRaw == null) {
      throw const NonAppException(
          'nonapp_missing_payload', 'renderer=a2ui 需要 payload/surface.json');
    }
    final messages = normalizeSurface(
      _decodeJson(surfaceRaw, 'payload/surface.json', 'nonapp_invalid_surface'),
    );
    // 先验后落：a2ui 0.3.0 对 schema 不合法的信封是在**渲染期**抛
    // A2uiValidationError（MessageProcessor.processMessages 在 initState 里），
    // 打开坏包会炸整页。客户端因此比服务端更严一层：只放行 basic 内置
    // 组件目录 + 受支持的 action 形状（见 assertSurfaceRenderable 注释）。
    assertSurfaceRenderable(messages);

    Map<String, dynamic>? dataDoc;
    final dataRaw = entries['payload/data.json'];
    if (dataRaw != null) {
      final doc = _decodeJson(dataRaw, 'payload/data.json', 'nonapp_invalid_data');
      if (doc is! Map) {
        throw const NonAppException('nonapp_invalid_data', 'payload/data.json 必须是对象');
      }
      dataDoc = Map<String, dynamic>.from(doc);
    }

    String? prompt;
    final promptRaw = entries['payload/prompt.txt'];
    if (promptRaw != null) {
      if (promptRaw.length > nonAppMaxPromptBytes) {
        throw const NonAppException('nonapp_invalid_prompt', 'payload/prompt.txt 超过 8KiB');
      }
      prompt = _decodeUtf8(promptRaw, 'payload/prompt.txt');
    }

    return NonAppPackage(
      manifest: manifest,
      messages: messages,
      data: dataDoc,
      prompt: prompt,
    );
  }
}

// ---------- 内部：校验 ----------

final RegExp _idRe = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
final RegExp _semverRe = RegExp(r'^\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.-]+)?$');

bool isValidNonAppName(Object? name) {
  if (name is! String || name.isEmpty || name.length > 64) return false;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name);
}

void _checkEntryName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('..') ||
      name.codeUnits.any((c) => c < 0x20) ||
      !nonAppAllowedEntries.contains(name)) {
    throw NonAppException('nonapp_unexpected_entry:$name', '不允许的包内条目：$name');
  }
}

/// 有界读取单条目：流式 inflate + 累计**真实输出**字节，超限立即失败。
///
/// `ArchiveFile.content` 走 `ZipFile._outputLimit`，即按条目**声明的**解压
/// 大小截断——声明值可伪造，高压缩比炸弹（如 64MiB 零字节压成几十 KB、头部
/// 声明 1000）看着只有 1KB，实际 deflate 流能展开几十 MB。这里取条目的
/// 原始压缩流（[ArchiveFile.rawContent]），交给 archive 4 的
/// `ZLibDecoder.decodeStream(..., maxOutputSize:)`：原生分块解码 + 输出上限
/// 由 `LimitedOutputStream` 逐块计数，峰值内存 = 上限 + 一块解码缓冲，
/// 不随真实载荷线性增长。
Uint8List _readEntryContent(ArchiveFile f) {
  final raw = f.rawContent;
  if (raw == null) {
    throw NonAppException('nonapp_invalid_payload:${f.name}', '条目内容不可读');
  }

  final compression = f.compression;
  if (compression == null || compression == CompressionType.none) {
    // 存储条目：原始内容就是载荷本身（包体 8MiB 上限已保证其大小）。
    final data = raw.readBytes();
    if (data.length > nonAppMaxEntryBytes) {
      throw NonAppException('nonapp_too_large', '条目 ${f.name} 解压后超过 8MiB');
    }
    return data;
  }
  if (compression != CompressionType.deflate) {
    throw NonAppException(
        'nonapp_invalid_payload:${f.name}', '不支持的压缩方法：$compression');
  }

  final output = OutputMemoryStream();
  try {
    // getStream(decompress: false) 取压缩原始流（默认的 true 会先按声明
    // 大小解压一遍）；maxOutputSize 是硬上限，超过即抛 ArchiveLimitException。
    ZLibDecoder().decodeStream(
      raw.getStream(decompress: false),
      output,
      raw: true,
      throwOnError: true,
      maxOutputSize: nonAppMaxEntryBytes,
    );
  } on ArchiveLimitException {
    output.clear();
    throw NonAppException('nonapp_too_large', '条目 ${f.name} 解压后超过 8MiB');
  } on Object catch (e) {
    output.clear();
    throw NonAppException('nonapp_invalid_payload:${f.name}', '条目解压失败（$e）');
  }
  return output.getBytes();
}

String _decodeUtf8(List<int> raw, String what) {
  try {
    return utf8.decode(raw);
  } on FormatException catch (e) {
    throw NonAppException('nonapp_invalid_payload:$what', '不是 UTF-8 文本（$e）');
  }
}

Object? _decodeJson(List<int> raw, String what, String code) {
  try {
    return jsonDecode(_decodeUtf8(raw, what));
  } on FormatException catch (e) {
    throw NonAppException('$code: JSON 解析失败（$e）', '$what 不是合法 JSON');
  }
}

NonAppManifest _parseManifest(Uint8List raw, String clientVersion) {
  final doc = _decodeJson(raw, 'manifest.json', 'nonapp_invalid_manifest');
  if (doc is! Map) {
    throw const NonAppException('nonapp_invalid_manifest', 'manifest.json 顶层必须是对象');
  }

  final version = doc['formatVersion'];
  if (version is! int || version != nonAppFormatVersion) {
    throw NonAppException(
        'nonapp_unsupported_version:$version', '不支持的包格式版本：$version（本机支持 v1）');
  }

  final id = doc['id'];
  if (id is! String || !_idRe.hasMatch(id)) {
    throw NonAppException('nonapp_invalid_id:$id', 'manifest.id 非法（只允许小写字母数字-下划线）');
  }
  final idStr = id;

  final name = doc['name'];
  if (!isValidNonAppName(name)) {
    throw NonAppException('nonapp_invalid_name:$name', 'manifest.name 非法（只允许字母数字-下划线，<=64）');
  }
  final nameStr = name! as String;

  final title = doc['title'];
  if (title is! String || title.length > nonAppMaxTitleChars) {
    throw const NonAppException('nonapp_invalid_manifest', 'manifest.title 必须是不超过 120 字符的字符串');
  }
  final titleStr = title;

  final renderer = doc['renderer'];
  if (renderer != 'html' && renderer != 'a2ui') {
    throw NonAppException('nonapp_unsupported_renderer:$renderer', '未知渲染器：$renderer');
  }
  final rendererStr = renderer as String;

  final createdAt = doc['createdAt'];
  if (createdAt is! int || createdAt <= 0) {
    throw const NonAppException('nonapp_invalid_manifest', 'manifest.createdAt 必须是 epoch 秒整数');
  }
  final createdAtInt = createdAt;

  final minAppVersion = doc['minAppVersion'];
  if (minAppVersion is! String || !_semverRe.hasMatch(minAppVersion)) {
    throw const NonAppException('nonapp_invalid_manifest', 'manifest.minAppVersion 必须是语义化版本');
  }
  final minAppVersionStr = minAppVersion;
  if (compareVersions(clientVersion, minAppVersionStr) < 0) {
    throw NonAppException(
        'nonapp_requires_app:$minAppVersionStr', '这个应用需要 NaN $minAppVersionStr 及以上（当前 $clientVersion）');
  }

  final brief = doc['brief'];
  if (brief != null && (brief is! String || brief.length > nonAppMaxBriefChars)) {
    throw const NonAppException('nonapp_invalid_manifest', 'manifest.brief 必须是不超过 2000 字符的字符串');
  }

  return NonAppManifest(
    formatVersion: nonAppFormatVersion,
    id: idStr,
    name: nameStr,
    title: titleStr.isEmpty ? nameStr : titleStr,
    renderer: rendererStr,
    createdAt: createdAtInt,
    minAppVersion: minAppVersionStr,
    brief: brief as String?,
    origin: doc['origin'] == nonAppOriginPrototype ? nonAppOriginPrototype : nonAppOriginApp,
  );
}

/// A2UI 消息序列归一：数组或 `{"messages":[...]}`，每项必须是对象。
List<Object?> normalizeSurface(Object? raw) {
  final List<Object?> messages;
  if (raw is List) {
    messages = List<Object?>.from(raw);
  } else if (raw is Map && raw['messages'] is List) {
    messages = List<Object?>.from(raw['messages'] as List);
  } else {
    throw const NonAppException('nonapp_invalid_surface', 'surface.json 必须是数组或 {"messages":[...]}');
  }
  for (var i = 0; i < messages.length; i++) {
    if (messages[i] is! Map) {
      throw NonAppException('nonapp_invalid_surface', 'surface.json 第 $i 项不是对象');
    }
  }
  if (messages.isEmpty) {
    throw const NonAppException('nonapp_invalid_surface', 'surface.json 消息序列为空');
  }
  return messages;
}

/// A2UI v1.0 basic 目录的内置组件（a2ui_flutter 0.3.0 的 v1_0 catalog）。
///
/// .nonapp 的 a2ui 载荷**只允许内置目录**（自定义 CatalogItem 是编译期 Dart
/// 代码，不能随文件分发——见 docs/plan-chat-stream-shell.md §1.1）。
/// basic 目录 v1.0 的 catalogId（A2uiCard 只注册这一个目录；别的 catalogId
/// 会在渲染期抛 A2uiCatalogError → 炸页，所以在门口拒掉）。
const String nonAppBasicCatalogId =
    'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json';

const Set<String> nonAppBasicComponents = {
  'Text',
  'Image',
  'Icon',
  'Video',
  'AudioPlayer',
  'Row',
  'Column',
  'List',
  'Card',
  'Tabs',
  'Modal',
  'Divider',
  'Button',
  'TextField',
  'CheckBox',
  'ChoicePicker',
  'Slider',
  'DateTimeInput',
};

/// A2UI v1.0 的**信封名**（a2ui_core 0.7.0 `_agentToRendererBodyKeys` +
/// v1.0 增量 `_agentToRendererV1BodyKeys`）。
///
/// 注意：旧文档里的 `surfaceUpdate` / `dataModelUpdate` **不是** v1.0 协议
/// 信封（后者叫 `updateComponents` / `updateDataModel`）；a2ui_core 对未知
/// 信封在 `processMessages` 里抛 `A2uiValidationError`（静态路径在 initState，
/// 打开坏包会炸整页），所以门口直接拒。
const Set<String> nonAppA2uiEnvelopes = {
  'createSurface',
  'updateComponents',
  'updateDataModel',
  'deleteSurface',
  'callRendererFunction',
  'agentFunctionResponse',
};

/// `.nonapp` a2ui 载荷声明的协议版本：包契约固定 v1.0。
///
/// a2ui_core 0.7.0 的 wire 字面量是 `'1.0'`（`A2uiProtocolVersion.v1_0`）；
/// `'v1.0'` / `'1.0.0'` 这类拼写会在解析期抛错。v0.9 序列不在包契约内
/// （createSurface 的 components 语义是 v1.0 才有的），一律拒。
const Set<String> nonAppA2uiVersions = {'1.0'};

/// 渲染前的浅层结构门（比服务端更严）：只放行「能确定不会炸渲染」的信封。
///
/// 为什么需要：a2ui 0.3.0 对 schema 不合法的信封在 `processMessages` 里抛
/// `A2uiValidationError`，而静态路径就在 `initState` 里调它——打开一个坏包
/// 会炸整页（不是让卡片内联报错）。客户端没有 JSON Schema 校验器，所以用
/// 白名单把攻击面收窄到「v1.0 信封 + 内置组件 + 受支持的 action 形状」：
///   · 每条消息必须有非空 `version`（且是 SDK 支持的 wire 值），并恰好包含
///     一个 v1.0 信封（见 [nonAppA2uiEnvelopes]）；
///   · `createSurface` / `updateComponents` 的 `surfaceId` 非空、
///     `components` 非空，组件名必须在 [nonAppBasicComponents]；
///   · action 只能是 `{"event": {"name": <非空字符串>}}` 或 `{"functionCall": {...}}`
///     （其它形状 = 渲染期 VALIDATION_FAILED）。
/// 更深的 props 形状仍由渲染器裁决；这一层只保证「不会因结构错炸页」。
void assertSurfaceRenderable(List<Object?> messages) {
  void checkComponent(Object? raw) {
    if (raw is! Map) {
      throw const NonAppException('nonapp_invalid_surface', 'surface.json 的组件不是对象');
    }
    final id = raw['id'];
    final name = raw['component'];
    if (id is! String || id.isEmpty) {
      throw const NonAppException('nonapp_invalid_surface', 'surface.json 的组件缺少 id');
    }
    if (name is! String || !nonAppBasicComponents.contains(name)) {
      throw NonAppException(
          'nonapp_invalid_surface', '组件 $id 的类型不受支持：$name（只能使用 basic 内置组件）');
    }
    final action = raw['action'];
    if (action == null) return;
    if (action is! Map) {
      throw NonAppException('nonapp_invalid_surface', '组件 $id 的 action 不是对象');
    }
    final event = action['event'];
    if (event is Map) {
      final eventName = event['name'];
      if (eventName is! String || eventName.isEmpty) {
        throw NonAppException(
            'nonapp_invalid_surface', '组件 $id 的 action.event.name 必须是非空字符串');
      }
      return;
    }
    if (action['functionCall'] is Map) return;
    throw NonAppException(
        'nonapp_invalid_surface', '组件 $id 的 action 形状不受支持（只允许 event/functionCall）');
  }

  String surfaceIdOf(Map body, String envelope) {
    final surfaceId = body['surfaceId'];
    if (surfaceId is! String || surfaceId.isEmpty) {
      throw NonAppException(
          'nonapp_invalid_surface', 'surface.json 的 $envelope.surfaceId 必须是非空字符串');
    }
    return surfaceId;
  }

  /// createSurface / updateComponents：组件表（若出现）必须是非空数组且逐项过门。
  void checkComponents(Map body, String envelope,
      {bool required = true, bool checkCatalog = false}) {
    if (checkCatalog) {
      final catalogId = body['catalogId'];
      if (catalogId != null && catalogId != nonAppBasicCatalogId) {
        throw NonAppException(
            'nonapp_invalid_surface', '不支持的 catalogId：$catalogId（只能使用 basic v1.0 内置目录）');
      }
    }
    final components = body['components'];
    if (components == null && !required) return;
    if (components is! List || components.isEmpty) {
      throw NonAppException(
          'nonapp_invalid_surface', 'surface.json 的 $envelope.components 必须是非空数组');
    }
    for (final component in components) {
      checkComponent(component);
    }
  }

  /// 每条消息引用的 surface 必须在本序列里先 createSurface（v1.0 处理器
  /// 对未创建 surface 的 update/delete 抛 A2uiIntegrityError）。
  final created = <String>{};
  final withComponents = <String>{};

  void requireCreated(String surfaceId, String envelope) {
    if (!created.contains(surfaceId)) {
      throw NonAppException(
          'nonapp_invalid_surface', 'surface.json 的 $envelope 引用了未创建的 surface：$surfaceId');
    }
  }

  for (final message in messages) {
    if (message is! Map) continue; // normalizeSurface 已挡；防御性
    // 外链门（a2ui 版）：basic 目录的 Image/Video/AudioPlayer 对 http(s)
    // 地址直接走 Image.network / 网络播放（a2ui_flutter-0.3.0 image.dart:47、
    // media.dart:131），dataModelUpdate 里的 URL 也会经绑定喂进这些组件——
    // 打开不受信包就会向任意外部地址发起请求，与「a2ui 内存渲染零服务依赖」
    // 相悖。`openUrl: null` 只禁用 openUrl 函数，拦不住这个。
    // catalogId 是结构字段（本身就是 https URL），只在 surface 信封里豁免。
    _assertNoA2uiExternalUrls(message);

    final version = message['version'];
    if (version is! String || version.isEmpty) {
      throw const NonAppException(
          'nonapp_invalid_surface', 'surface.json 每条消息必须声明非空 version（A2UI v1.0 信封）');
    }
    if (!nonAppA2uiVersions.contains(version)) {
      throw NonAppException(
          'nonapp_invalid_surface', '不支持的 A2UI 协议版本：$version（支持 ${nonAppA2uiVersions.join(' / ')}）');
    }

    final envelopes = [
      for (final key in nonAppA2uiEnvelopes)
        if (message.containsKey(key)) key,
    ];
    if (envelopes.length != 1) {
      throw const NonAppException(
          'nonapp_invalid_surface', 'surface.json 每条消息必须且只能包含一个 A2UI 信封');
    }
    final envelope = envelopes.single;
    final body = message[envelope];
    if (body is! Map) {
      throw NonAppException(
          'nonapp_invalid_surface', 'surface.json 的 $envelope 信封必须是对象');
    }

    switch (envelope) {
      case 'createSurface':
        final surfaceId = surfaceIdOf(body, envelope);
        if (!created.add(surfaceId)) {
          throw NonAppException(
              'nonapp_invalid_surface', 'surface.json 重复创建 surface：$surfaceId');
        }
        // v1.0 允许 createSurface 不带 components（由后续 updateComponents
        // 补齐）；但出现时不得为空数组。
        checkComponents(body, envelope, required: false, checkCatalog: true);
        if (body['components'] != null) withComponents.add(surfaceId);
      case 'updateComponents':
        final surfaceId = surfaceIdOf(body, envelope);
        requireCreated(surfaceId, envelope);
        checkComponents(body, envelope);
        withComponents.add(surfaceId);
      case 'updateDataModel':
        requireCreated(surfaceIdOf(body, envelope), envelope);
      case 'deleteSurface':
        final surfaceId = surfaceIdOf(body, envelope);
        requireCreated(surfaceId, envelope);
        // 删除后允许再 createSurface 同一 id（协议允许 reset 式序列）。
        created.remove(surfaceId);
        withComponents.remove(surfaceId);
      case 'callRendererFunction':
        final surfaceId = body['surfaceId'];
        if (surfaceId != null) {
          if (surfaceId is! String || surfaceId.isEmpty) {
            throw const NonAppException(
                'nonapp_invalid_surface', 'surface.json 的 callRendererFunction.surfaceId 必须是非空字符串');
          }
          requireCreated(surfaceId, envelope);
        }
      default:
        // agentFunctionResponse：v1.0 才有，更深形状由渲染器裁决
        // （A2uiCard 已把渲染期异常降级为卡内错误占位）。
        break;
    }
  }

  // 打包应用的每个 surface 至少要有一批组件：createSurface 自带或后续
  // updateComponents 补齐。只创建不填充 = 打开后空白页（不是崩溃，但
  // 「文件即应用」不接受空应用）。
  for (final surfaceId in created) {
    if (!withComponents.contains(surfaceId)) {
      throw NonAppException(
          'nonapp_invalid_surface', 'surface.json 的 surface $surfaceId 没有任何组件（components 必须非空）');
    }
  }
}

/// 递归扫描一条 A2UI 消息里的**外链地址字面量**（http(s):// 或协议相对 //）。
///
/// 只看「整串就是一个地址」的字符串（trim 后以协议开头），不做子串匹配：
/// 展示文案里提到链接不该被误伤，而真正的 url/poster 属性值一定是整串地址。
/// `catalogId` 是 surface 信封的结构字段（本身是 https URL），按信封上下文豁免
/// ——不做键名全局豁免，避免 data model 里同名字段走私地址。
void _assertNoA2uiExternalUrls(Object? node) {
  void walk(Object? value) {
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v.startsWith('http://') || v.startsWith('https://') || v.startsWith('//')) {
        throw NonAppException(
            'nonapp_a2ui_external_refs', 'a2ui 载荷含外链地址（$value）——必须零外链本地渲染');
      }
      // 运行时拼接的地址在字面量层面看不出来（`'${a}${b}'`），但拼接后的
      // URL 一定含 `://`；data model 里的碎片也在这里被拦下。
      if (v.contains('://')) {
        throw NonAppException(
            'nonapp_a2ui_external_refs', 'a2ui 载荷含外链地址片段（$value）——必须零外链本地渲染');
      }
      return;
    }
    if (value is Map) {
      // 函数调用（v1.0 用 `@call`，v0.9 用 `call`）可以在运行时从 data model
      // 拼出地址：basic 目录的 formatString 就是官方提供的拼接函数，
      // Image.network 会把结果直接当 URL 请求。不可信 .nonapp 只允许
      // 「无绑定的静态模板」，openUrl 一律拒绝（查看器也不提供回调）。
      final call = value['@call'] ?? value['call'];
      if (call is String) {
        final name = call.trim();
        if (name == 'openUrl') {
          throw const NonAppException(
              'nonapp_a2ui_external_refs', 'a2ui 载荷含打开外链的动作——必须零外链本地渲染');
        }
        if (name == 'formatString') {
          final args = value['args'];
          final template = args is Map ? args['value'] : null;
          if (template is! String || template.contains(r'$') || template.contains('{')) {
            throw const NonAppException(
                'nonapp_a2ui_external_refs', 'a2ui 载荷含动态拼接文本（可能拼出外链）——必须零外链本地渲染');
          }
        }
      }
      final isSurfaceEnvelope = value.containsKey('surfaceId');
      value.forEach((key, child) {
        if (isSurfaceEnvelope && key.toString() == 'catalogId') return;
        walk(child);
      });
      return;
    }
    if (value is List) {
      for (final child in value) {
        walk(child);
      }
    }
  }

  walk(node);
}

/// 语义化版本比较（数值元组；`1.2` == `1.2.0`；预发布后缀按字符串比）。
///
/// 返回 <0 / 0 / >0，与 `package:pub_semver` 的 compareTo 同向。
int compareVersions(String a, String b) {
  List<int> core(String v) {
    final base = v.split(RegExp(r'[-+]')).first;
    final parts = base.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }

  String suffix(String v) {
    final idx = v.indexOf(RegExp(r'[-+]'));
    return idx < 0 ? '' : v.substring(idx);
  }

  final pa = core(a);
  final pb = core(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  // 数值核心相同：无后缀 > 有后缀（1.2 > 1.2.0-rc1），双方同形才比字符串。
  final sa = suffix(a);
  final sb = suffix(b);
  if (sa == sb) return 0;
  if (sa.isEmpty) return 1;
  if (sb.isEmpty) return -1;
  return sa.compareTo(sb);
}

// ---------- 内部：HTML 零外链保守预筛 ----------

/// `xmlns="http://www.w3.org/2000/svg"` 这类命名空间声明不是可加载引用。
final RegExp _xmlnsRe = RegExp(
  r'''\sxmlns(?::[A-Za-z0-9_-]+)?\s*=\s*(?:"[^"]*"|'[^']*')''',
  caseSensitive: false,
);

/// 服务端 `hotapp._html_ok` 的同判据集（script/link/img 的 src|href|srcset）。
final RegExp _serverAttrRefRe = RegExp(
  r'''<(?:script|link|img)\b[^>]*?\b(?:src|href|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
  caseSensitive: false,
  dotAll: true,
);

/// 离线预筛的属性面：比旧后端更宽（iframe、video、a 等元素的 src|href|poster…）
/// ——只严不松是允许的。
final RegExp _offlineAttrRefRe = RegExp(
  r'''<(?:script|link|img|iframe|video|audio|source|embed|object|track|input|a)\b[^>]*?\b(?:src|href|srcset|poster|data)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _cssUrlRe =
    RegExp(r'''url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)''', caseSensitive: false);
final RegExp _cssImportRe = RegExp(
  r'''@import\s+(?:url\(\s*)?(?:"([^"]*)"|'([^']*)'|([^\s;)]+))''',
  caseSensitive: false,
);

bool _isExternalRef(String value) {
  final v = value.trim().toLowerCase();
  if (v.isEmpty) return false;
  return v.startsWith('http://') || v.startsWith('https://') || v.startsWith('//') || v.startsWith('/');
}

List<String> _collectRefs(String html, RegExp attrRefRe) {
  final found = <String>[];
  void scan(String value) {
    // srcset 是逗号分隔的候选列表（URL 后的 2x 描述符丢弃）
    for (final candidate in value.split(',')) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty) continue;
      final token = trimmed.split(RegExp(r'\s+')).first;
      if (_isExternalRef(token)) found.add(token);
    }
  }

  for (final m in attrRefRe.allMatches(html)) {
    scan(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
  }
  for (final m in _cssUrlRe.allMatches(html)) {
    scan(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
  }
  for (final m in _cssImportRe.allMatches(html)) {
    scan(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
  }
  return found;
}

void _assertHtmlStructure(String html) {
  // 与服务端 `_html_ok` 同判据：<body / </html / >200 字符
  final htmlLower = html.toLowerCase();
  if (!htmlLower.contains('<body') || !htmlLower.contains('</html>') || html.length <= 200) {
    throw const NonAppException('nonapp_html_invalid', 'HTML 缺少 <body>/</html> 结构或长度不足');
  }
}

/// **旧在线实现的等价**门（parse 用）：与历史 `_html_ok` 同一引用面。
///
/// 这一层只做「旧实现会拒的包提前拒掉」，不能比它严：否则旧实现接受的包
/// （如 `<a href="https://…">`，旧正则只覆盖 script/link/img）会在客户端
/// 解不开，导出→再导入自家应用走不通。真正落盘/打开前的安全门是
/// `assertHtmlOfflineSafe`。
void assertHtmlServerCompat(String html) {
  final found = _collectRefs(html, _serverAttrRefRe);
  if (found.isNotEmpty) {
    throw NonAppException(
        'nonapp_html_external_refs', 'HTML 含外链引用（${found.take(3).join(', ')}）');
  }
  _assertHtmlStructure(html);
}

/// **离线**门（安装进本地库 / file:// 打开前）：只严不松。
///
/// 抛 [NonAppException]（`nonapp_html_invalid` / `nonapp_html_external_refs`）。
/// file:// 下没有服务端 CSP 与零外链门，这一层就是唯一防线。
void assertHtmlOfflineSafe(String html) {
  // 1) 服务端等价面（同判据，先拦最确定的）
  assertHtmlServerCompat(html);

  // 2) 全文扫 http(s)://（xmlns 声明豁免：内联 SVG 的常见形态）
  final scrubbed = html.replaceAll(_xmlnsRe, '');
  final lower = scrubbed.toLowerCase();
  if (lower.contains('http://') || lower.contains('https://')) {
    throw const NonAppException(
        'nonapp_html_external_refs', 'HTML 含 http(s) 外链引用——离线打开必须全内联零外链');
  }

  // 3) 更宽的引用面（iframe、video、a 等元素 + poster/data）
  final found = _collectRefs(html, _offlineAttrRefRe);
  if (found.isNotEmpty) {
    throw NonAppException(
        'nonapp_html_external_refs', 'HTML 含外链引用（${found.take(3).join(', ')}）');
  }
}

/// 本地预览的 CSP（沿用历史实现同一条策略）。
///
/// file:// 页没有 HTTP 响应头，只能把策略经 `<meta http-equiv>` 注入——它是
/// 「零外链」静态扫描之外的第二道防线：JS 字符串拼接/编码的地址绕过扫描，
/// 但过不了 CSP（review nonapp-5）。策略收紧/放宽都要同时更新这里的测试
/// 断言（CSP 必须先于页面内容生效）。
const String nonAppOfflineCsp =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
    "img-src data: blob:; font-src data:; media-src data: blob:; "
    "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

/// 把 [nonAppOfflineCsp] 以 meta 注入**文档最前**（DOCTYPE 之后）：策略必须
/// 早于页面上的第一个脚本生效。
///
/// 早期实现插在 `<head>` 的第一个标签之后，但 HTML 解析器允许内联
/// `<script>` 出现在 `<head>` 之前（"before head" 插入模式）——这样的脚本
/// 会先执行，CSP meta 反而晚到。把它放在 DOCTYPE 之后（没有 DOCTYPE 就放在
/// 字节 0），无论包把脚本放在哪里都先吃到策略。幂等性不保证——缓存写入是
/// 一次性动作，对同一载荷重复注入只会叠一条等价策略。
String injectNonAppCsp(String html) {
  final meta =
      '<meta http-equiv="Content-Security-Policy" content="$nonAppOfflineCsp">';
  // 保留开头的 DOCTYPE（否则文档进入 quirks mode）；没有就以字节 0 为锚。
  final doctype = RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false).firstMatch(html);
  final index = doctype?.end ?? 0;
  return html.replaceRange(index, index, meta);
}
