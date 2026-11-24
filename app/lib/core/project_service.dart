// Local project library: `.ddp` save / open / list without a server.
//
// One project is one `.ddp` container (see `ddp.dart`) holding exactly one
// source document. Design notes (PRD / UI copy / design spec) are not a sidecar
// file: they ride inside the source as two HTML comments, exactly like
// annotations, so a copied or moved `.ddp` never loses them.
//
//   <!-- nondesign:design {...} -->
//   <!-- nondesign:docs {"prd":"…","ui":"…"} -->
//
// Invariants inherited from the existing documents (real incidents):
//  * the payload must never contain a literal `-->` — the engine’s comment
//    scanner stops at the first one, so `>` is escaped to `\u003e`;
//  * comments go last: their position must not drift when artboards are
//    renamed or deleted;
//  * JSON is written compact and UTF-8-native (no ASCII escaping), matching
//    the Rust/Python writers.
//
// Writes are atomic: bytes go to a sibling temp file, then a rename replaces
// the target. A crash mid-save leaves the previous project intact.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_paths.dart';
import 'ddp.dart';

/// Default design spec embedded in a fresh project.
///
/// Keep in sync with `DesignSpec.defaults` (`models.dart`); duplicates are
/// intentional here so the project layer has no dependency on UI models.
const Map<String, dynamic> defaultProjectDesign = {
  'v': 1,
  'palette': {
    'primary': '#6E7BFF',
    'background': '#F7F8FA',
    'surface': '#FFFFFF',
    'text': '#14161A',
    'muted': '#6B7280',
    'danger': '#DC2626',
    'success': '#16A34A',
  },
  'typography': {'h1': 32, 'h2': 24, 'body': 14},
  'spacing': [4, 8, 12, 16, 24, 32],
  'radius': {'sm': 8, 'md': 12, 'lg': 16},
  'rules': ['正文对比度 ≥ 4.5', '8pt 间距节奏', '按钮圆角 8', '列表 3 行以上加分隔线', '按钮文案 2–4 字'],
  'notes': '',
};

final RegExp _designComment = RegExp(
  r'<!--\s*nondesign:design\s+([\s\S]*?)\s*-->',
);
final RegExp _docsComment = RegExp(r'<!--\s*nondesign:docs\s+([\s\S]*?)\s*-->');
final RegExp _blankRuns = RegExp(r'\n{3,}');
final RegExp _trailingSpace = RegExp(r'\s+$');

/// Fresh, mutable copy of [defaultProjectDesign].
Map<String, dynamic> defaultProjectDocs() => {
  'prd': '',
  'ui': '',
  'design': _deepCopy(defaultProjectDesign),
};

/// Merges [value] over the defaults, dropping values of the wrong type.
///
/// Mirrors the Rust/Python normalizer: `palette` / `typography` / `radius`
/// merge key by key; `spacing` keeps numeric entries as ints; `rules` are
/// stringified; `notes` must be a string.
Map<String, dynamic> normalizeProjectDesign(Object? value) {
  final design = _deepCopy(defaultProjectDesign);
  if (value is! Map) return design;
  for (final key in const ['palette', 'typography', 'radius']) {
    final incoming = value[key];
    if (incoming is Map) {
      final merged = Map<String, dynamic>.from(design[key] as Map);
      incoming.forEach((k, v) => merged['$k'] = v);
      design[key] = merged;
    }
  }
  final spacing = value['spacing'];
  if (spacing is List && spacing.isNotEmpty) {
    design['spacing'] = [
      for (final entry in spacing)
        if (entry is num) entry.toInt(),
    ];
  }
  final rules = value['rules'];
  if (rules is List) {
    design['rules'] = rules.map((e) => e.toString()).toList(growable: false);
  }
  final notes = value['notes'];
  if (notes is String) design['notes'] = notes;
  design['v'] = 1;
  return design;
}

/// Removes both project comments from [mbt] and tidies the leftover blank
/// lines (the engine tolerates them; this keeps diffs readable).
String stripProjectMetadata(String mbt) {
  if (mbt.isEmpty) return '';
  var cleaned = mbt.replaceAll(_designComment, '');
  cleaned = cleaned.replaceAll(_docsComment, '');
  cleaned = cleaned.replaceAll(_blankRuns, '\n\n');
  return cleaned.replaceFirst(_trailingSpace, '');
}

/// Appends the project comments to [mbt].
///
/// [docs] is the `{prd, ui, design, prototype?}` shape produced by
/// `Docs.toJson()`（`prototype` 是设计模块的项目内验证原型元数据）。
/// Comments are always appended last, separated by one blank line, and
/// terminated with a newline — the exact shape the previous writer produced.
String withProjectMetadata(String mbt, Map<String, dynamic> docs) {
  final base = stripProjectMetadata(mbt);
  final design = docs['design'];
  final designJson = _encodeMetadata(
    (design is Map && design.isNotEmpty) ? design : defaultProjectDesign,
  );
  final prototype = docs['prototype'];
  final payload = _encodeMetadata({
    'prd': docs['prd'] ?? '',
    'ui': docs['ui'] ?? '',
    if (prototype is Map && prototype.isNotEmpty) 'prototype': prototype,
  });
  return '$base\n\n<!-- nondesign:design $designJson -->\n'
      '<!-- nondesign:docs $payload -->\n';
}

/// Reads the project comments back out of [mbt].
///
/// Missing or malformed comments fall back to defaults — a damaged note must
/// never prevent the project itself from opening.
Map<String, dynamic> parseProjectMetadata(String mbt) {
  final docs = defaultProjectDocs();
  if (mbt.isEmpty) return docs;
  final design = _designComment.firstMatch(mbt);
  if (design != null) {
    try {
      docs['design'] = normalizeProjectDesign(jsonDecode(design.group(1)!));
    } catch (_) {
      // Keep defaults.
    }
  }
  final payload = _docsComment.firstMatch(mbt);
  if (payload != null) {
    try {
      final value = jsonDecode(payload.group(1)!);
      if (value is Map) {
        final prd = value['prd'];
        final ui = value['ui'];
        docs['prd'] = prd is String ? prd : '';
        docs['ui'] = ui is String ? ui : '';
        final prototype = value['prototype'];
        if (prototype is Map && prototype.isNotEmpty) {
          docs['prototype'] = Map<String, dynamic>.from(prototype);
        }
      }
    } catch (_) {
      // Keep defaults.
    }
  }
  return docs;
}

/// One project file as listed by [ProjectService.list].
class ProjectEntry {
  final String path;
  final String name;
  final int bytes;

  /// Modification time in **seconds** since epoch (matches the previous
  /// server payload the UI already formats).
  final double modified;

  const ProjectEntry({
    required this.path,
    required this.name,
    required this.bytes,
    required this.modified,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'bytes': bytes,
    'modified': modified,
  };

  @override
  String toString() => 'ProjectEntry($name, $bytes bytes)';
}

/// Outcome of [ProjectService.save].
class ProjectSaveResult {
  final bool ok;
  final String? path;
  final int bytes;

  /// Internal error code; null on success.
  final String? error;

  const ProjectSaveResult({
    required this.ok,
    this.path,
    this.bytes = 0,
    this.error,
  });
}

/// Outcome of [ProjectService.open].
class ProjectOpenResult {
  final bool ok;
  final String? path;
  final String? mbt;
  final Map<String, dynamic>? docs;
  final int bytes;

  /// True when the file is password-protected and the supplied password was
  /// missing or wrong. The UI should prompt and retry.
  final bool needPassword;

  /// Internal error code; null on success.
  final String? error;

  const ProjectOpenResult({
    required this.ok,
    this.path,
    this.mbt,
    this.docs,
    this.bytes = 0,
    this.needPassword = false,
    this.error,
  });
}

/// Outcome of [ProjectService.list].
class ProjectListResult {
  final bool ok;
  final String? dir;
  final List<ProjectEntry> projects;
  final String? error;

  const ProjectListResult({
    required this.ok,
    this.dir,
    this.projects = const [],
    this.error,
  });
}

/// Local project library.
///
/// The default directory comes from [AppPaths.projectsRoot] (desktop
/// `~/Documents/NoNDesign`, mobile app documents). Tests and alternate
/// libraries inject a root instead of changing global state.
class ProjectService {
  ProjectService({Future<Directory> Function()? root})
    : _root = root ?? AppPaths.projectsRoot;

  final Future<Directory> Function() _root;

  /// The default library directory (created if missing).
  Future<Directory> defaultDirectory() => _root();

  /// Writes [mbt] (with [docs] embedded when non-empty) to [path].
  ///
  /// A missing `.ddp` extension is added; `~` is expanded; parent directories
  /// are created. The write is atomic.
  Future<ProjectSaveResult> save({
    required String path,
    required String mbt,
    String password = '',
    Map<String, dynamic> docs = const {},
  }) async {
    final target = File(_withDdpSuffix(expandProjectPath(path)));
    try {
      await target.parent.create(recursive: true);
      final document = docs.isEmpty ? mbt : withProjectMetadata(mbt, docs);
      final payload = await DdpCodec.encrypt(document, password: password);
      await _writeAtomic(target, payload);
      return ProjectSaveResult(
        ok: true,
        path: target.path,
        bytes: payload.length,
      );
    } on DdpException catch (e) {
      return ProjectSaveResult(ok: false, path: target.path, error: e.code);
    } catch (e) {
      return ProjectSaveResult(
        ok: false,
        path: target.path,
        error: 'ddp_write_failed',
      );
    }
  }

  /// Reads the project at [path].
  ///
  /// Missing files return `file_not_found`; a locked file without the right
  /// password returns [ProjectOpenResult.needPassword] with
  /// `ddp_password_required` / `ddp_authentication_failed`.
  Future<ProjectOpenResult> open(String path, {String password = ''}) async {
    final target = File(expandProjectPath(path));
    if (!await target.exists()) {
      return ProjectOpenResult(
        ok: false,
        path: target.path,
        error: 'file_not_found',
      );
    }
    final Uint8List bytes;
    try {
      bytes = await target.readAsBytes();
    } catch (_) {
      return ProjectOpenResult(
        ok: false,
        path: target.path,
        error: 'ddp_read_failed',
      );
    }
    try {
      final mbt = await DdpCodec.decrypt(bytes, password: password);
      return ProjectOpenResult(
        ok: true,
        path: target.path,
        mbt: mbt,
        docs: parseProjectMetadata(mbt),
        bytes: bytes.length,
      );
    } on DdpException catch (e) {
      final needsPassword =
          e.code == 'ddp_password_required' ||
          e.code == 'ddp_authentication_failed';
      return ProjectOpenResult(
        ok: false,
        path: target.path,
        needPassword: needsPassword,
        error: e.code,
      );
    } catch (_) {
      return ProjectOpenResult(
        ok: false,
        path: target.path,
        error: 'ddp_read_failed',
      );
    }
  }

  /// Lists `.ddp` files in [dir], or in the default library when null.
  ///
  /// Sorted by modification time, newest first. An explicitly requested
  /// directory that does not exist reports `dir_not_found` instead of being
  /// created (the caller may have mistyped a path); the default library root
  /// is created on demand by [AppPaths.projectsRoot].
  Future<ProjectListResult> list({String? dir}) async {
    final explicit = dir != null && dir.trim().isNotEmpty;
    final Directory target;
    try {
      if (explicit) {
        target = Directory(expandProjectPath(dir));
        if (!await target.exists()) {
          return ProjectListResult(
            ok: false,
            dir: target.path,
            error: 'dir_not_found',
          );
        }
      } else {
        target = await _root();
        if (!await target.exists()) {
          await target.create(recursive: true);
        }
      }
    } catch (_) {
      return ProjectListResult(ok: false, dir: dir, error: 'dir_not_found');
    }

    final entries = <ProjectEntry>[];
    try {
      await for (final entity in target.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _baseName(entity.path);
        if (!name.toLowerCase().endsWith('.ddp')) continue;
        try {
          final stat = await entity.stat();
          entries.add(
            ProjectEntry(
              path: entity.path,
              name: name.substring(0, name.length - 4),
              bytes: stat.size,
              modified: stat.modified.millisecondsSinceEpoch / 1000.0,
            ),
          );
        } catch (_) {
          // File vanished between listing and stat — skip it.
        }
      }
    } catch (_) {
      return ProjectListResult(
        ok: false,
        dir: target.path,
        error: 'dir_list_failed',
      );
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return ProjectListResult(ok: true, dir: target.path, projects: entries);
  }

  /// Parses the project comments out of an already-open document.
  Map<String, dynamic> parseDocs(String mbt) => parseProjectMetadata(mbt);

  static Future<void> _writeAtomic(File target, Uint8List payload) async {
    final parent = target.parent;
    final temp = File(
      '${parent.path}${Platform.pathSeparator}'
      '.${_baseName(target.path)}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsBytes(payload, flush: true);
      try {
        await temp.rename(target.path);
      } on FileSystemException {
        // Windows cannot replace an existing file with rename; deleting first
        // is the best available fallback there. POSIX keeps the atomic path.
        if (await target.exists()) await target.delete();
        await temp.rename(target.path);
      }
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // Best-effort cleanup; the save result already carries the failure.
      }
    }
  }
}

/// Expands a leading `~` and normalizes nothing else (the reference writer
/// returned the path as given, which the UI stores verbatim).
String expandProjectPath(String path) {
  if (path == '~') return _homeDirectory() ?? path;
  if (path.startsWith('~/') || path.startsWith('~\\')) {
    final home = _homeDirectory();
    if (home != null) {
      return '$home${Platform.pathSeparator}${path.substring(2)}';
    }
  }
  return path;
}

/// Adds or replaces the `.ddp` extension (case-insensitive).
String _withDdpSuffix(String path) {
  final trimmed = _withoutTrailingSeparators(path);
  final slash = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  final dot = trimmed.lastIndexOf('.');
  final baseNameStart = slash + 1;
  if (dot > baseNameStart && trimmed.substring(dot).toLowerCase() == '.ddp') {
    return trimmed;
  }
  if (dot > baseNameStart) {
    return '${trimmed.substring(0, dot)}.ddp';
  }
  return '$trimmed.ddp';
}

/// Drops trailing separators the way `Path` does, without breaking a Windows
/// drive root (`C:\`).
String _withoutTrailingSeparators(String path) {
  var result = path;
  while (result.length > 1 &&
      (result.endsWith('/') || result.endsWith('\\')) &&
      !(result.length == 3 && result[1] == ':')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

String _baseName(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

String? _homeDirectory() {
  if (Platform.isWindows) {
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) return profile;
  }
  final home = Platform.environment['HOME'];
  return (home == null || home.isEmpty) ? null : home;
}

String _encodeMetadata(Object? value) =>
    jsonEncode(value).replaceAll('>', r'\u003e');

Map<String, dynamic> _deepCopy(Map<String, dynamic> source) =>
    jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
