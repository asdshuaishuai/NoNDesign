/// 工作台项目单一打包容器（`nan.pack/1`）。
///
/// 设计 / 3D / 视频 / 3D 视频 / 音乐工作台的项目事实源从「目录里散落多个
/// JSON」收敛为一个可携带的单一文件（与设计面的 `.ddp` 同一定位，但不加密、
/// 不做认证，只做完整性校验）。格式是确定性 UTF-8 文本，便于版本对比与人工
/// 排障：
///
///     nan.pack/1\n
///     <紧凑单行 JSON payload>\n
///     crc32=<8 位小写十六进制>\n
///
///  · 头部行固定 `nan.pack/<version>`；本实现只写 / 只认 version 1，其它版本
///    显性拒绝（[WorkbenchPackFailureCode.versionUnsupported]）；
///  · payload 是单行紧凑 JSON：顶层字段固定为 version / kind / name / title /
///    docs / spec / files / createdAt / updatedAt；所有嵌套对象的键按字典序，
///    因此同一输入（含固定时间戳）得到同一字节；
///  · 第三行是 payload 的 IEEE CRC32（与 `ddp.dart` 同多项式 0xEDB88320），
///    解码先校验和、再解析 JSON——篡改、截断不会静默变成「空项目」；
///  · `files` 是相对 POSIX 路径 → 文本内容；二进制文件不进容器（目录收集
///    只收 UTF-8 文本，跳过的二进制文件与产物/缓存写进
///    [WorkbenchPackScan] 报告）。
///
/// 与 `ddp.dart` 的关系：DDP 的 zstd / CRC32 原语是 `DdpCodec` 的**文件私有**
/// 实现，且 `DdpCodec.encrypt/decrypt` 是异步、带 DDP1/DDP2 专用 magic 与
/// 加密 AAD 的二进制容器；本层 [WorkbenchPack.encode] 要求同步返回字符串，
/// 在不改 `ddp.dart`（只读）的前提下无法直接复用，因此按任务约定退回
/// 「确定性 JSON + CRC32 尾校验」。CRC32 多项式和 `ddp.dart` 一致；将来若把
/// DDP 的 CRC32 提成公共原语，只需替换这里的私有实现。
///
/// 本层纯 Dart（无 Flutter / 无引擎 / 无 WebView）：容器字节只由输入决定，
/// 文件系统只出现在 [WorkbenchPack.writeTo] / [WorkbenchPack.readFrom] /
/// [filesFromDirectory] 三个边界上。
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 容器格式版本：本实现写出的唯一版本，也是唯一接受的版本。
const int workbenchPackVersion = 1;

/// 容器 magic（完整头部行是 `nan.pack/<version>`）。
const String workbenchPackMagic = 'nan.pack';

/// 校验和行的前缀（完整行是 `crc32=<8 位十六进制>`）。
const String workbenchPackChecksumPrefix = 'crc32=';

/// payload（JSON 文本）的字节上限，与 DDP 的源文档上限一致（8 MiB）。
///
/// 超出即显性失败（[WorkbenchPackFailureCode.tooLarge]），不截断。
const int workbenchPackMaxPayloadBytes = 8 * 1024 * 1024;

/// [WorkbenchPackFailure] 的稳定机器码。
///
/// 只用于测试、日志与后续工具信封；用户可见文案由 UI 层按 code 映射（
/// `docs/copy-glossary.md` 纪律：不把裸错误码直接上屏）。
abstract final class WorkbenchPackFailureCode {
  const WorkbenchPackFailureCode._();

  /// 不是 `nan.pack` 容器：magic 行缺失、行数不对、校验和行格式坏。
  static const String invalidContainer = 'pack_invalid_container';

  /// 头部（或 payload 的 version 字段）不是 1。
  static const String versionUnsupported = 'pack_version_unsupported';

  /// payload 的 CRC32 与尾部校验和不一致（篡改 / 截断 / 传输损坏）。
  static const String checksumFailed = 'pack_checksum_failed';

  /// checksum 通过但 payload 不是合法 JSON（或根不是 JSON 对象）。
  static const String jsonInvalid = 'pack_json_invalid';

  /// 必填字段缺失（version / kind / name / title / files）。
  static const String missingField = 'pack_missing_field';

  /// 字段类型不对，或取值不合法（空 name、非法 ISO 时间戳等）。
  static const String invalidField = 'pack_invalid_field';

  /// `kind` 不在 design / three / video / video3d / music 之内。
  static const String unknownKind = 'pack_unknown_kind';

  /// `files` 的路径不是安全的相对 POSIX 路径（绝对路径 / `..` / 盘符 / 重名）。
  static const String invalidPath = 'pack_invalid_path';

  /// `spec` 不是 JSON 安全值（非有限数字、非字符串键、DateTime 等）。
  static const String invalidSpec = 'pack_invalid_spec';

  /// 文本无法按 UTF-8 无损编码（例如未配对的 UTF-16 代理项）。
  static const String invalidText = 'pack_invalid_text';

  /// payload 超过 [workbenchPackMaxPayloadBytes]。
  static const String tooLarge = 'pack_too_large';

  /// 读 / 写 / 列目录等文件系统失败。
  static const String ioFailed = 'pack_io_failed';
}

/// 打包容器读写失败时的统一异常。
///
/// [code] 是稳定的机器码（见 [WorkbenchPackFailureCode]）；[message] 是内部
/// 诊断（含字段名 / 路径 / 底层文件系统错误），**只进日志与折叠的技术详情**，
/// 不直接上屏。
final class WorkbenchPackFailure implements Exception {
  const WorkbenchPackFailure(this.code, this.message);

  /// 稳定机器码。
  final String code;

  /// 内部诊断信息。
  final String message;

  @override
  String toString() => 'WorkbenchPackFailure($code: $message)';
}

/// 工作台类型（也是容器可用的 `kind` 白名单与扩展名映射的唯一来源）。
enum WorkbenchPackKind {
  design('design', '.ddp'),
  three('three', '.n3d'),
  video('video', '.nvdo'),
  video3d('video3d', '.n3v'),
  music('music', '.nmu');

  const WorkbenchPackKind(this.wire, this.extension);

  /// JSON / `filesFromDirectory` 参数里的稳定字符串值。
  final String wire;

  /// 项目单一容器文件的扩展名（含点）。
  final String extension;

  /// 按 wire 字符串查枚举；未知 / 非字符串返回 null（由调用方显性失败）。
  static WorkbenchPackKind? tryParse(Object? wire) {
    for (final WorkbenchPackKind kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// 按工作台类型（wire 字符串）返回单一容器扩展名（design→`.ddp`、
/// three→`.n3d`、video→`.nvdo`、video3d→`.n3v`、music→`.nmu`）。
///
/// 未知 kind 显性失败，不猜默认扩展名。
String packExtensionFor(String kind) {
  final WorkbenchPackKind? parsed = WorkbenchPackKind.tryParse(kind);
  if (parsed == null) {
    throw WorkbenchPackFailure(
      WorkbenchPackFailureCode.unknownKind,
      'unknown workbench kind: "$kind"',
    );
  }
  return parsed.extension;
}

/// 一个工作台项目的单一打包容器（不可变值对象）。
///
/// 字段与 `nan.pack/1` 容器一一对应；构造时即校验（kind / name / 时间戳 /
/// spec 的 JSON 安全性 / files 路径安全性），所以合法的对象一定能被
/// [encode]（唯一例外是超过 8 MiB 的 payload，那时显性抛
/// [WorkbenchPackFailureCode.tooLarge]）。
final class WorkbenchPack {
  /// 构造一个容器值对象。
  ///
  /// [files] 的键必须是相对 POSIX 路径（`\` 会被归一成 `/`）；值是该文件的
  /// UTF-8 文本内容。二进制内容不属于容器，调用方应在目录收集阶段跳过
  /// （见 [scanWorkbenchDirectory]）。
  WorkbenchPack({
    required this.kind,
    required String name,
    required this.title,
    this.docs,
    Object? spec,
    Map<String, String>? files,
    this.createdAt,
    this.updatedAt,
  }) : name = _validatedName(name),
       spec = _canonicalSpec(spec),
       files = _normalizedFiles(files ?? const <String, String>{}) {
    if (createdAt != null) {
      _validateTimestamp('createdAt', createdAt!);
    }
    if (updatedAt != null) {
      _validateTimestamp('updatedAt', updatedAt!);
    }
  }

  /// 从 [toMap] 的 JSON 对象重建；字段缺失 / 类型错误 / 未知 kind 都显性失败。
  ///
  /// 未知字段被忽略（向前兼容）；必填字段为 version / kind / name / title /
  /// files，可选字段为 docs / spec / createdAt / updatedAt（缺省均为 null）。
  factory WorkbenchPack.fromMap(Object? raw) {
    final Map<String, Object?> map = _jsonObject(raw);

    final Object? versionRaw = _requireField(map, 'version');
    if (versionRaw is! int) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "version" must be an integer',
      );
    }
    if (versionRaw != workbenchPackVersion) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.versionUnsupported,
        'unsupported container version $versionRaw (expected $workbenchPackVersion)',
      );
    }

    final Object? kindRaw = _requireField(map, 'kind');
    if (kindRaw is! String) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "kind" must be a string',
      );
    }
    final WorkbenchPackKind? kind = WorkbenchPackKind.tryParse(kindRaw);
    if (kind == null) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.unknownKind,
        'unknown workbench kind: "$kindRaw"',
      );
    }

    final String name = _requireString(map, 'name');
    final String title = _requireString(map, 'title');
    final String? docs = _optionalString(map, 'docs');
    final String? createdAt = _optionalString(map, 'createdAt');
    final String? updatedAt = _optionalString(map, 'updatedAt');
    final Map<String, String> files = _filesFromJson(
      _requireField(map, 'files'),
    );

    return WorkbenchPack(
      kind: kind,
      name: name,
      title: title,
      docs: docs,
      spec: map['spec'],
      files: files,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// 解码 [encode] 写出的容器文本。
  ///
  /// 校验顺序：行数 / magic / 版本 → 校验和格式 → CRC32 → JSON 解析 →
  /// 字段校验。任何一步失败都抛显性 [WorkbenchPackFailure]，不会返回半成品。
  factory WorkbenchPack.decode(String text) {
    final List<String> lines = _decodeLines(text);
    if (lines.length != 3) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidContainer,
        'expected 3 lines (header / payload / checksum), got ${lines.length}',
      );
    }

    final int version = _parseHeaderVersion(lines[0]);
    if (version != workbenchPackVersion) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.versionUnsupported,
        'unsupported container version $version (expected $workbenchPackVersion)',
      );
    }

    final String checksumLine = lines[2];
    if (!checksumLine.startsWith(workbenchPackChecksumPrefix)) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidContainer,
        'missing "crc32=<8 hex digits>" checksum line',
      );
    }
    final String checksumText = checksumLine.substring(
      workbenchPackChecksumPrefix.length,
    );
    if (!_checksumPattern.hasMatch(checksumText)) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidContainer,
        'checksum must be exactly 8 hexadecimal digits',
      );
    }
    final int expectedChecksum = int.parse(checksumText, radix: 16);

    final Uint8List payloadBytes = _utf8Bytes(lines[1], 'payload');
    if (payloadBytes.length > workbenchPackMaxPayloadBytes) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.tooLarge,
        'payload is ${payloadBytes.length} bytes '
        '(limit $workbenchPackMaxPayloadBytes)',
      );
    }
    if (_crc32(payloadBytes) != expectedChecksum) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.checksumFailed,
        'payload CRC32 does not match the checksum line',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(lines[1]);
    } on FormatException catch (error) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.jsonInvalid,
        'payload is not valid JSON: ${error.message}',
      );
    }
    return WorkbenchPack.fromMap(decoded);
  }

  /// 容器格式版本（本实现恒为 [workbenchPackVersion]）。
  final int version = workbenchPackVersion;

  /// 工作台类型。
  final WorkbenchPackKind kind;

  /// 项目名（单人可读标识；不含路径分隔符，允许中文）。
  final String name;

  /// 展示标题（可为空字符串）。
  final String title;

  /// 人读文档（Markdown 等文本；可为空 / 缺省）。
  final String? docs;

  /// 机器可校验的规范（任意 JSON 安全值，已按键字典序规范化）。
  final Object? spec;

  /// 相对 POSIX 路径 → 文本内容（已按路径字典序）。
  final Map<String, String> files;

  /// 创建时间（ISO-8601 字符串；可选）。
  final String? createdAt;

  /// 更新时间（ISO-8601 字符串；可选）。
  final String? updatedAt;

  /// 本项目单一容器的扩展名（含点）。
  String get extension => kind.extension;

  /// 建议的文件名：`<name><extension>`（仅用于展示；磁盘名由调用方决定）。
  String get suggestedFileName => '$name$extension';

  /// 稳定 JSON 视图（字段名与顺序固定）。
  ///
  /// `files` 返回一份新的共享内容 Map；`spec` 已是规范化 JSON 树。往返
  /// `toMap()` → [WorkbenchPack.fromMap] 不丢字段（可选字段保留 null）。
  Map<String, Object?> toMap() => <String, Object?>{
    'version': version,
    'kind': kind.wire,
    'name': name,
    'title': title,
    'docs': docs,
    'spec': spec,
    'files': Map<String, String>.from(files),
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  /// 编码为 `nan.pack/1` 文本。
  ///
  /// 同一输入（含固定时间戳）→ 同一字节：payload 的嵌套对象键按字典序、
  /// `files` 路径按字典序，数字用 JSON 的稳定编码。行尾固定 LF，末尾带一个
  /// 换行。任何非 JSON 安全内容 / 未配对代理项 / 超限 payload 显性失败。
  String encode() {
    // 顶层也按键字典序规范化：payload 的字段顺序不依赖 [toMap] 的书写顺序，
    // 同一输入在任何构造路径下都得到同一字节。
    final Object? canonical = _canonicalJsonValue(
      toMap(),
      'pack',
      WorkbenchPackFailureCode.invalidField,
    );
    final String payload = _encodeJson(canonical);
    final Uint8List payloadBytes = _utf8Bytes(payload, 'payload');
    if (payloadBytes.length > workbenchPackMaxPayloadBytes) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.tooLarge,
        'payload is ${payloadBytes.length} bytes '
        '(limit $workbenchPackMaxPayloadBytes)',
      );
    }
    return '$workbenchPackMagic/$version\n$payload\n'
        '$workbenchPackChecksumPrefix${_crc32Hex(payloadBytes)}\n';
  }

  /// 原子写入 [file]（同目录临时文件 + rename）。
  ///
  /// 成功时目标路径要么是完整旧文件、要么是完整新文件（rename 原子替换）；
  /// 失败时旧文件保持原样，临时文件被清理。目标路径若是目录 / 符号链接，或
  /// 父目录不可写，显性抛 [WorkbenchPackFailureCode.ioFailed]，绝不删旧内容。
  Future<void> writeTo(File file) async {
    final String text = encode();
    final Directory directory = file.parent;
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File temporary = File(
      '${directory.path}/.${_leafName(file)}.$stamp.tmp',
    );
    try {
      directory.createSync(recursive: true);
      temporary.writeAsStringSync(text, flush: true);
      _renameIntoPlace(temporary, file, stamp);
    } on WorkbenchPackFailure {
      rethrow;
    } catch (error) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.ioFailed,
        'write failed for "${file.path}": $error',
      );
    } finally {
      _deleteQuietly(temporary);
    }
  }

  /// 读取 [file] 并解码；文件缺失 / 无法读 / 容器损坏都显性失败。
  static Future<WorkbenchPack> readFrom(File file) async {
    final String text;
    try {
      text = await file.readAsString();
    } catch (error) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.ioFailed,
        'read failed for "${file.path}": $error',
      );
    }
    return WorkbenchPack.decode(text);
  }

  // --------------------------------------------------------------- 字段校验

  static final RegExp _checksumPattern = RegExp(r'^[0-9a-fA-F]{8}$');

  static String _validatedName(String name) {
    if (name.trim().isEmpty) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "name" must not be empty',
      );
    }
    if (name.length > 256) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "name" is too long (limit 256 characters)',
      );
    }
    if (name == '.' || name == '..' || name.contains('/')) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "name" must not look like a path: "$name"',
      );
    }
    for (final int rune in name.runes) {
      if (rune < 0x20 || rune == 0x7F) {
        throw const WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidField,
          'field "name" must not contain control characters',
        );
      }
    }
    return name;
  }

  static void _validateTimestamp(String field, String value) {
    if (DateTime.tryParse(value) == null) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "$field" must be an ISO-8601 timestamp: "$value"',
      );
    }
  }

  static Map<String, String> _normalizedFiles(Map<String, String> raw) {
    final SplayTreeMap<String, String> sorted = SplayTreeMap<String, String>();
    for (final MapEntry<String, String> entry in raw.entries) {
      final String path = _normalizeRelativePath(entry.key);
      if (sorted.containsKey(path)) {
        throw WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidPath,
          'duplicate file path after normalization: "$path"',
        );
      }
      sorted[path] = entry.value;
    }
    return UnmodifiableMapView<String, String>(sorted);
  }

  /// 相对 POSIX 路径校验：拒绝绝对路径、`..` / `.` / 空段、盘符与重名。
  static String _normalizeRelativePath(String raw) {
    final String slashed = raw.replaceAll('\\', '/');
    if (slashed.isEmpty) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidPath,
        'file path must not be empty',
      );
    }
    if (slashed.startsWith('/')) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidPath,
        'absolute file path is not allowed: "$raw"',
      );
    }
    final List<String> segments = slashed.split('/');
    for (final String segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidPath,
          'unsafe relative file path: "$raw"',
        );
      }
      if (segment.contains(':')) {
        throw WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidPath,
          'file path must not contain a drive letter or ":": "$raw"',
        );
      }
      for (final int rune in segment.runes) {
        if (rune < 0x20 || rune == 0x7F) {
          throw WorkbenchPackFailure(
            WorkbenchPackFailureCode.invalidPath,
            'file path must not contain control characters: "$raw"',
          );
        }
      }
    }
    return segments.join('/');
  }

  static Object? _canonicalSpec(Object? spec) => _canonicalJsonValue(
    spec,
    'spec',
    WorkbenchPackFailureCode.invalidSpec,
    Set<Object>.identity(),
  );

  /// 深度校验并规范化 JSON 值：对象转按键字典序的 `SplayTreeMap`，其它原语
  /// 原样返回。非 JSON 安全值（非有限数字 / 非字符串键 / 自定义对象 / 循环
  /// 引用）显性失败。
  static Object? _canonicalJsonValue(
    Object? value,
    String path,
    String code, [
    Set<Object>? visiting,
  ]) {
    if (value == null || value is String || value is bool) return value;
    if (value is int) return value;
    if (value is double) {
      if (!value.isFinite) {
        throw WorkbenchPackFailure(
          code,
          '$path is not a finite JSON number: $value',
        );
      }
      return value;
    }
    if (value is List) {
      final Set<Object> seen = visiting ?? Set<Object>.identity();
      if (!seen.add(value)) {
        throw WorkbenchPackFailure(code, '$path has a cyclic JSON reference');
      }
      try {
        return <Object?>[
          for (var i = 0; i < value.length; i++)
            _canonicalJsonValue(value[i], '$path/$i', code, seen),
        ];
      } finally {
        seen.remove(value);
      }
    }
    if (value is Map) {
      final Set<Object> seen = visiting ?? Set<Object>.identity();
      if (!seen.add(value)) {
        throw WorkbenchPackFailure(code, '$path has a cyclic JSON reference');
      }
      try {
        final SplayTreeMap<String, Object?> sorted =
            SplayTreeMap<String, Object?>();
        for (final MapEntry<Object?, Object?> entry in value.entries) {
          final Object? key = entry.key;
          if (key is! String) {
            throw WorkbenchPackFailure(
              code,
              '$path has a non-string JSON key (${key.runtimeType})',
            );
          }
          sorted[key] = _canonicalJsonValue(
            entry.value,
            '$path/$key',
            code,
            seen,
          );
        }
        return sorted;
      } finally {
        seen.remove(value);
      }
    }
    throw WorkbenchPackFailure(
      code,
      '$path is not a JSON value (${value.runtimeType})',
    );
  }

  /// 规范化 JSON 文本：嵌套对象键按字典序、无多余空白；编码失败显性失败。
  static String _encodeJson(Object? value) {
    try {
      return jsonEncode(value);
    } on JsonUnsupportedObjectError catch (error) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidSpec,
        'payload contains a non-JSON value: ${error.unsupportedObject}',
      );
    }
  }

  static Uint8List _utf8Bytes(String text, String what) {
    try {
      return Uint8List.fromList(utf8.encode(text));
    } on ArgumentError catch (error) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidText,
        '$what is not losslessly UTF-8 encodable: $error',
      );
    }
  }

  // --------------------------------------------------------------- 解码辅助

  static List<String> _decodeLines(String text) {
    var value = text;
    if (value.endsWith('\n')) value = value.substring(0, value.length - 1);
    return <String>[
      for (final String line in value.split('\n'))
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    ];
  }

  static int _parseHeaderVersion(String header) {
    const String prefix = '$workbenchPackMagic/';
    if (!header.startsWith(prefix)) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidContainer,
        'missing "nan.pack/<version>" header line',
      );
    }
    final String versionText = header.substring(prefix.length);
    if (!_versionPattern.hasMatch(versionText)) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidContainer,
        'malformed container version: "$versionText"',
      );
    }
    return int.parse(versionText);
  }

  static final RegExp _versionPattern = RegExp(r'^[0-9]+$');

  /// JSON 对象视图；非对象 → `pack_json_invalid`，非字符串键 → `pack_invalid_field`。
  static Map<String, Object?> _jsonObject(Object? raw) {
    if (raw is! Map) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.jsonInvalid,
        'payload root must be a JSON object, got ${raw.runtimeType}',
      );
    }
    final Map<String, Object?> map = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw const WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidField,
          'payload object has a non-string key',
        );
      }
      map[key] = entry.value;
    }
    return map;
  }

  static Object? _requireField(Map<String, Object?> map, String field) {
    if (!map.containsKey(field)) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.missingField,
        'missing required field "$field"',
      );
    }
    return map[field];
  }

  static String _requireString(Map<String, Object?> map, String field) {
    final Object? value = _requireField(map, field);
    if (value is! String) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "$field" must be a string',
      );
    }
    return value;
  }

  static String? _optionalString(Map<String, Object?> map, String field) {
    if (!map.containsKey(field)) return null;
    final Object? value = map[field];
    if (value == null) return null;
    if (value is! String) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "$field" must be a string or null',
      );
    }
    return value;
  }

  static Map<String, String> _filesFromJson(Object? raw) {
    if (raw is! Map) {
      throw const WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        'field "files" must be a JSON object of path → text',
      );
    }
    final Map<String, String> files = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is! String) {
        throw const WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidField,
          'field "files" contains a non-string path',
        );
      }
      if (value is! String) {
        throw WorkbenchPackFailure(
          WorkbenchPackFailureCode.invalidField,
          'file "$key" must be a string (binary files do not belong in a pack)',
        );
      }
      files[key] = value;
    }
    return files;
  }

  // ------------------------------------------------------------------ 写盘

  static String _leafName(File file) {
    final List<String> segments = file.path
        .replaceAll('\\', '/')
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    return segments.isEmpty ? 'pack' : segments.last;
  }

  /// 同目录 rename 原子替换。
  ///
  /// POSIX 下 rename 覆盖已有文件是原子的；Windows 上目标文件在场时 rename
  /// 可能失败，此时先挪旧文件到备份、换入新文件，换入失败则把备份挪回——
  /// 两种情况都以「旧文件不被破坏」为底线；目标若是目录或符号链接，直接抛错
  /// （绝不删除旧目录/旧链接）。
  static void _renameIntoPlace(File temporary, File target, String stamp) {
    try {
      temporary.renameSync(target.path);
      return;
    } on FileSystemException catch (firstError) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        target.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) {
        // notFound / directory / link：不删除任何旧内容，保留原始诊断。
        rethrow;
      }
      final File backup = File('${target.path}.bak-$stamp');
      try {
        target.renameSync(backup.path);
      } on FileSystemException {
        throw firstError;
      }
      try {
        temporary.renameSync(target.path);
      } catch (error) {
        try {
          if (!target.existsSync() && backup.existsSync()) {
            backup.renameSync(target.path);
          }
        } on FileSystemException {
          throw FileSystemException(
            'atomic replace failed and the previous file is preserved at '
            '"${backup.path}"',
            target.path,
          );
        }
        rethrow;
      }
      _deleteQuietly(backup);
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 清理失败不能盖掉原始错误。
    }
  }

  // --------------------------------------------------------------------- CRC32

  static List<int>? _crcTable;

  /// IEEE CRC32（与 `ddp.dart` 同多项式 0xEDB88320；该实现是 DdpCodec 私有，
  /// 本层独立实现以便同步 encode）。
  static int _crc32(List<int> data) {
    final List<int> table = _crcTable ??= List<int>.generate(256, (int n) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      return c;
    }, growable: false);
    var crc = 0xFFFFFFFF;
    for (final int byte in data) {
      crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String _crc32Hex(List<int> data) =>
      _crc32(data).toRadixString(16).padLeft(8, '0');
}

/// 目录收集的报告：哪些文本进了 [files]，哪些因为二进制 / 排除规则 / 白名单
/// 被跳过（跳过必须可见，不静默吞掉）。
final class WorkbenchPackScan {
  const WorkbenchPackScan({
    required this.files,
    this.skippedBinary = const <String>[],
    this.skippedExcluded = const <String>[],
    this.skippedNotIncluded = const <String>[],
    this.skippedLinks = const <String>[],
  });

  /// 收录的文本文件：相对 POSIX 路径 → UTF-8 文本（按路径字典序）。
  final Map<String, String> files;

  /// 不是合法 UTF-8 文本、因此没有进容器的文件（相对路径，按字典序）。
  final List<String> skippedBinary;

  /// 命中默认 / 调用方排除规则（产物、缓存、临时目录）的路径。
  ///
  /// 目录以自身相对路径出现一次（其子树整体被剪掉）。
  final List<String> skippedExcluded;

  /// 有 `include` 白名单但未命中的文件（相对路径）。
  final List<String> skippedNotIncluded;

  /// 符号链接（不跟随，避免把项目根之外的路径卷进容器）。
  final List<String> skippedLinks;

  /// 是否一个文本文件都没收到。
  bool get isEmpty => files.isEmpty;

  /// 收录文件数。
  int get fileCount => files.length;

  @override
  String toString() =>
      'WorkbenchPackScan(files: $fileCount, '
      'binary: ${skippedBinary.length}, '
      'excluded: ${skippedExcluded.length}, '
      'notIncluded: ${skippedNotIncluded.length}, '
      'links: ${skippedLinks.length})';
}

/// 目录收集的默认排除规则（产物 / 缓存 / VCS 元数据）。
///
/// 无 `/` 的规则匹配**路径末段**（因此 `history` 规则会剪掉任意深度下的
/// `history/` 子树）；含 `/` 的规则匹配完整相对路径。支持 `*`（段内任意
/// 字符）与 `**`（跨段任意字符）。
const Set<String> workbenchPackDefaultExcludes = <String>{
  'build-state.json',
  '.tmp',
  '.cache',
  '.git',
  '.dart_tool',
  'node_modules',
  'history',
  'artifacts',
  'build',
  'dist',
  'coverage',
};

/// 把工作台项目目录收集成「相对 POSIX 路径 → 文本内容」，供各工作台 store
/// 迁移进单一容器。
///
/// 语义：
///  * 递归收集 [dir] 下的**文本**文件（严格 UTF-8；二进制文件跳过，原因见
///    [scanWorkbenchDirectory] 报告）；
///  * 默认排除 [workbenchPackDefaultExcludes]（`build-state.json` / `history/`
///    / `artifacts/` / `.tmp/` 等产物与缓存），[exclude] 在其之上追加；
///  * [include] 非空时只收命中的文件（`*.json`、`src/**` 这类简单通配）；
///  * 符号链接不跟随、目录按名字排序遍历、返回按路径字典序，同一目录 → 同一
///    结果；项目目录不存在 / 不是目录 / 读取失败都显性抛
///    [WorkbenchPackFailureCode.ioFailed]。
///
/// 需要「跳过了哪些文件」的完整报告时用 [scanWorkbenchDirectory]；本函数是它
/// 的 `files` 视图。
Map<String, String> filesFromDirectory(
  Directory dir, {
  Set<String> include = const <String>{},
  Set<String> exclude = const <String>{},
}) {
  return scanWorkbenchDirectory(dir, include: include, exclude: exclude).files;
}

/// 与 [filesFromDirectory] 同语义，但返回完整报告（含被跳过的二进制 / 产物 /
/// 白名单外文件与符号链接）。
WorkbenchPackScan scanWorkbenchDirectory(
  Directory dir, {
  Set<String> include = const <String>{},
  Set<String> exclude = const <String>{},
}) {
  final FileSystemEntityType dirType = FileSystemEntity.typeSync(
    dir.path,
    followLinks: false,
  );
  if (dirType == FileSystemEntityType.notFound) {
    throw WorkbenchPackFailure(
      WorkbenchPackFailureCode.ioFailed,
      'directory does not exist: "${dir.path}"',
    );
  }
  if (dirType != FileSystemEntityType.directory) {
    throw WorkbenchPackFailure(
      WorkbenchPackFailureCode.ioFailed,
      'not a directory (or a symbolic link): "${dir.path}"',
    );
  }

  final List<String> includePatterns = _normalizeScanPatterns(
    include,
    'include',
  );
  final List<String> excludePatterns = <String>[
    ..._normalizeScanPatterns(exclude, 'exclude'),
    ...workbenchPackDefaultExcludes,
  ];

  final SplayTreeMap<String, String> collected = SplayTreeMap<String, String>();
  final List<String> skippedBinary = <String>[];
  final List<String> skippedExcluded = <String>[];
  final List<String> skippedNotIncluded = <String>[];
  final List<String> skippedLinks = <String>[];

  void walk(Directory current, String prefix) {
    final List<FileSystemEntity> entries;
    try {
      entries = current.listSync(followLinks: false);
    } catch (error) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.ioFailed,
        'list failed for "${current.path}": $error',
      );
    }
    entries.sort(
      (FileSystemEntity a, FileSystemEntity b) =>
          _entityLeaf(a.path).compareTo(_entityLeaf(b.path)),
    );
    for (final FileSystemEntity entity in entries) {
      final String leaf = _entityLeaf(entity.path);
      final String relative = prefix.isEmpty ? leaf : '$prefix/$leaf';
      if (_matchesAny(excludePatterns, relative, leaf)) {
        skippedExcluded.add(relative);
        continue;
      }
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        walk(Directory(entity.path), relative);
        continue;
      }
      if (type == FileSystemEntityType.link) {
        skippedLinks.add(relative);
        continue;
      }
      if (type != FileSystemEntityType.file) continue;
      if (includePatterns.isNotEmpty &&
          !_matchesAny(includePatterns, relative, leaf)) {
        skippedNotIncluded.add(relative);
        continue;
      }
      final List<int> bytes;
      try {
        bytes = File(entity.path).readAsBytesSync();
      } catch (error) {
        throw WorkbenchPackFailure(
          WorkbenchPackFailureCode.ioFailed,
          'read failed for "${entity.path}": $error',
        );
      }
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        skippedBinary.add(relative);
        continue;
      }
      collected[relative] = text;
    }
  }

  walk(dir, '');

  skippedBinary.sort();
  skippedExcluded.sort();
  skippedNotIncluded.sort();
  skippedLinks.sort();
  return WorkbenchPackScan(
    files: UnmodifiableMapView<String, String>(collected),
    skippedBinary: List<String>.unmodifiable(skippedBinary),
    skippedExcluded: List<String>.unmodifiable(skippedExcluded),
    skippedNotIncluded: List<String>.unmodifiable(skippedNotIncluded),
    skippedLinks: List<String>.unmodifiable(skippedLinks),
  );
}

// ------------------------------------------------------------------- 扫描辅助

String _entityLeaf(String path) {
  final List<String> segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  return segments.isEmpty ? path : segments.last;
}

List<String> _normalizeScanPatterns(Set<String> patterns, String field) {
  final List<String> out = <String>[];
  for (final String pattern in patterns) {
    final String normalized = pattern
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^\./'), '');
    final String cleaned = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (cleaned.isEmpty) {
      throw WorkbenchPackFailure(
        WorkbenchPackFailureCode.invalidField,
        '$field pattern must not be empty',
      );
    }
    out.add(cleaned);
  }
  return out;
}

bool _matchesAny(List<String> patterns, String relative, String leaf) {
  for (final String pattern in patterns) {
    if (_matchesPattern(pattern, relative, leaf)) return true;
  }
  return false;
}

bool _matchesPattern(String pattern, String relative, String leaf) {
  final String candidate = pattern.contains('/') ? relative : leaf;
  if (!pattern.contains('*')) return candidate == pattern;
  return _globRegExp(pattern).hasMatch(candidate);
}

final Map<String, RegExp> _globCache = <String, RegExp>{};

RegExp _globRegExp(String pattern) {
  return _globCache.putIfAbsent(pattern, () {
    final StringBuffer buffer = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final String char = pattern[i];
      if (char == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buffer.write('.*');
          i++;
        } else {
          buffer.write('[^/]*');
        }
      } else if (r'\^$.|?+()[]{}'.contains(char)) {
        buffer.write('\\$char');
      } else {
        buffer.write(char);
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  });
}
