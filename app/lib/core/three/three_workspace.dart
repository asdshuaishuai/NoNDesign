/// 3D 项目 v2 工作区：`spec.json` / `plan.json` / `src|scene.json` /
/// `artifacts/` / `judge/`，以及旧布局（`three-spec.json` / `scene.js` /
/// `build-state.json`）的只读迁移。
///
/// 契约见 `docs/three-contract.md` §3/§9：
/// * code 模式 `src/*.js` 是事实源；scene 模式 `scene.json` 是事实源；
/// * 旧文件**不静默删**；首次迁移只新增 v2 文件并写 `migration.json`；
/// * artifacts 对 agent 只读（本层只负责读写事实源与收产物）。
library;

import 'dart:convert';
import 'dart:io';

import '../creative/creative_plan.dart';
import '../creative/creative_schema.dart';
import '../creative/creative_spec.dart';
import 'three_plan.dart';

/// v2 工作区里的固定路径。
abstract final class ThreeWorkspaceLayout {
  const ThreeWorkspaceLayout._();

  static const String specFile = 'spec.json';
  static const String planFile = 'plan.json';
  static const String sceneFile = 'scene.json';
  static const String srcDir = 'src';
  static const String publicDir = 'public';
  static const String artifactsDir = 'artifacts';
  static const String judgeDir = 'judge';
  static const String migrationFile = 'migration.json';

  /// 旧布局文件（迁移只读，不删）。
  static const String legacySpecFile = 'three-spec.json';
  static const String legacySceneFile = 'scene.js';
  static const String legacyStateFile = 'build-state.json';
}

/// 工作区操作失败（内部代号 + 原始诊断；界面经人话映射）。
final class ThreeWorkspaceFailure implements Exception {
  const ThreeWorkspaceFailure(this.code, [this.detail = '']);

  final String code;
  final String detail;

  @override
  String toString() =>
      'ThreeWorkspaceFailure($code${detail.isEmpty ? '' : ': $detail'})';
}

/// 工作区失败码 → 用户可见一句话（原始码只进技术详情）。
String threeWorkspaceFailureMessage(Object? error) {
  final String code = error is ThreeWorkspaceFailure ? error.code : '';
  return switch (code) {
    'invalid_name' => '场景名只能用字母、数字和短横线',
    'no_project' => '没有找到这个 3D 项目',
    'no_legacy' => '这个项目还没有新工作区，也没有可迁移的旧规范',
    'legacy_spec_invalid' => '旧规范读不出来，先修复它再迁移',
    'plan_invalid' => '这份计划还没通过校验：先把精确尺寸和验收补上',
    'invalid_path' => '内部文件路径不合法',
    _ => '3D 工作区操作没有完成，请稍后再试',
  };
}

/// 项目模式：`code`（src 事实源）/ `scene`（scene.json 事实源）/ `legacy`（未迁移）。
enum ThreeAuthoringMode { code, scene, legacy }

/// 列表行（工作台项目下拉用）。
final class ThreeWorkspaceEntry {
  const ThreeWorkspaceEntry({
    required this.name,
    required this.mode,
    required this.migrated,
    this.legacyCurrentPass = '',
    this.legacyBlocked = false,
  });

  final String name;
  final ThreeAuthoringMode mode;
  final bool migrated;
  final String legacyCurrentPass;
  final bool legacyBlocked;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'mode': mode.name,
    'migrated': migrated,
    if (legacyCurrentPass.isNotEmpty) 'legacy_current': legacyCurrentPass,
    if (legacyBlocked) 'legacy_blocked': true,
  };
}

/// 一个 v2 项目（只读视图；写操作经 [ThreeWorkspaceStore]）。
final class ThreeWorkspaceProject {
  const ThreeWorkspaceProject({
    required this.name,
    required this.dir,
    required this.mode,
    required this.migrated,
    this.spec,
    this.plan,
    this.sceneJson,
    this.sourceFiles = const <String>[],
    this.issues = const <String>[],
    this.legacy = const <String, Object?>{},
  });

  final String name;
  final String dir;
  final ThreeAuthoringMode mode;
  final bool migrated;
  final CreativeSpec? spec;
  final CreativePlan3d? plan;
  final Map<String, Object?>? sceneJson;

  /// `src/` 下的相对文件（code 模式事实源清单）。
  final List<String> sourceFiles;

  /// 读取/校验问题（迁移草案 WARN 也在这里；不阻断打开）。
  final List<String> issues;
  final Map<String, Object?> legacy;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'dir': dir,
    'mode': mode.name,
    'migrated': migrated,
    if (spec != null) 'spec': spec!.toJson(),
    if (plan != null) 'plan': plan!.toJson(),
    if (sceneJson != null) 'scene': sceneJson,
    'source_files': sourceFiles,
    if (issues.isNotEmpty) 'issues': issues,
    if (legacy.isNotEmpty) 'legacy': legacy,
  };
}

/// 一次迁移的结果。
final class ThreeMigrationResult {
  const ThreeMigrationResult({
    required this.name,
    required this.alreadyMigrated,
    required this.wroteSpec,
    required this.wrotePlan,
    required this.copiedScene,
    required this.planWarnings,
    this.mode = ThreeAuthoringMode.code,
  });

  final String name;
  final bool alreadyMigrated;
  final bool wroteSpec;
  final bool wrotePlan;
  final bool copiedScene;
  final List<String> planWarnings;
  final ThreeAuthoringMode mode;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': true,
    'name': name,
    'already_migrated': alreadyMigrated,
    'wrote_spec': wroteSpec,
    'wrote_plan': wrotePlan,
    'copied_scene': copiedScene,
    'mode': mode.name,
    if (planWarnings.isNotEmpty) 'plan_warnings': planWarnings,
    'message': alreadyMigrated
        ? '这个 3D 项目已经是新工作区，无需迁移'
        : '已生成 spec.json / plan.json${copiedScene ? ' 并复制 scene.js 到 src/' : ''}；旧文件保留，plan 是迁移草案需补精确尺寸',
  };
}

/// v2 工作区读写（纯文件系统；无 UI/引擎依赖）。
class ThreeWorkspaceStore {
  ThreeWorkspaceStore(this.root);

  /// `<用户文档>/NoNDesign/3d`。
  final Directory root;

  static final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_-]+$');

  Directory projectDir(String name) {
    if (name.isEmpty || !_namePattern.hasMatch(name)) {
      throw ThreeWorkspaceFailure('invalid_name', name);
    }
    return Directory('${root.path}/$name');
  }

  /// 建齐 v2 目录骨架（src/public/artifacts/judge）；只建目录不写事实源。
  void ensureLayout(String name) {
    final Directory dir = projectDir(name);
    dir.createSync(recursive: true);
    for (final String sub in <String>[
      ThreeWorkspaceLayout.srcDir,
      ThreeWorkspaceLayout.publicDir,
      ThreeWorkspaceLayout.artifactsDir,
      ThreeWorkspaceLayout.judgeDir,
    ]) {
      Directory('${dir.path}/$sub').createSync(recursive: true);
    }
  }

  Future<List<ThreeWorkspaceEntry>> list() async {
    if (!root.existsSync()) return const <ThreeWorkspaceEntry>[];
    final List<Directory> dirs = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final List<ThreeWorkspaceEntry> out = <ThreeWorkspaceEntry>[];
    for (final Directory dir in dirs) {
      final String name = dir.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (!_namePattern.hasMatch(name)) continue;
      final bool hasSpec = File('${dir.path}/${ThreeWorkspaceLayout.specFile}')
          .existsSync();
      final bool hasLegacySpec = File(
        '${dir.path}/${ThreeWorkspaceLayout.legacySpecFile}',
      ).existsSync();
      final bool hasLegacyState = File(
        '${dir.path}/${ThreeWorkspaceLayout.legacyStateFile}',
      ).existsSync();
      if (!hasSpec && !hasLegacySpec && !hasLegacyState) continue;
      String current = '';
      bool blocked = false;
      if (hasLegacyState) {
        try {
          final Object? state = jsonDecode(
            File('${dir.path}/${ThreeWorkspaceLayout.legacyStateFile}')
                .readAsStringSync(),
          );
          if (state is Map) {
            current = (state['current'] ?? '').toString();
            blocked = state['blocked'] == true;
          }
        } catch (_) {
          current = 'corrupt';
        }
      }
      out.add(
        ThreeWorkspaceEntry(
          name: name,
          mode: hasSpec ? _modeOf(dir) : ThreeAuthoringMode.legacy,
          migrated: hasSpec,
          legacyCurrentPass: current,
          legacyBlocked: blocked,
        ),
      );
    }
    return out;
  }

  Future<ThreeWorkspaceProject> read(String name) async {
    final Directory dir = projectDir(name);
    if (!dir.existsSync()) throw ThreeWorkspaceFailure('no_project', name);
    final bool migrated = File('${dir.path}/${ThreeWorkspaceLayout.specFile}')
        .existsSync();
    final List<String> issues = <String>[];
    CreativeSpec? spec;
    CreativePlan3d? plan;
    Map<String, Object?>? sceneJson;
    final Map<String, Object?> legacy = <String, Object?>{};

    if (migrated) {
      final CreativeParseResult<CreativeSpec> specResult = CreativeSpec.parse(
        _readJsonFile(File('${dir.path}/${ThreeWorkspaceLayout.specFile}')),
      );
      if (specResult.value != null) {
        spec = specResult.value;
      } else {
        issues.addAll(
          specResult.validation.issues.map(
            (issue) => 'spec ${issue.code}: ${issue.message}',
          ),
        );
      }
      final CreativeParseResult<CreativePlan> planResult = CreativePlan.parse(
        _readJsonFile(File('${dir.path}/${ThreeWorkspaceLayout.planFile}')),
      );
      if (planResult.value is CreativePlan3d) {
        plan = planResult.value! as CreativePlan3d;
        final ThreePlanValidation validation = validateThreePlan(plan.toJson());
        issues.addAll(
          validation.allIssues
              .where((issue) => issue.blocking)
              .map((issue) => 'plan ${issue.code}: ${issue.message}'),
        );
      } else {
        issues.addAll(
          planResult.validation.issues.map(
            (issue) => 'plan ${issue.code}: ${issue.message}',
          ),
        );
      }
      final File sceneFile = File(
        '${dir.path}/${ThreeWorkspaceLayout.sceneFile}',
      );
      if (sceneFile.existsSync()) {
        try {
          final Object? decoded = jsonDecode(sceneFile.readAsStringSync());
          if (decoded is Map) sceneJson = Map<String, Object?>.from(decoded);
        } catch (error) {
          issues.add('scene.json 解析失败：$error');
        }
      }
    } else {
      for (final String legacyFile in <String>[
        ThreeWorkspaceLayout.legacySpecFile,
        ThreeWorkspaceLayout.legacyStateFile,
        ThreeWorkspaceLayout.legacySceneFile,
      ]) {
        if (File('${dir.path}/$legacyFile').existsSync()) {
          legacy[legacyFile] = 'demo';
        }
      }
    }

    return ThreeWorkspaceProject(
      name: name,
      dir: dir.path,
      mode: migrated ? _modeOf(dir) : ThreeAuthoringMode.legacy,
      migrated: migrated,
      spec: spec,
      plan: plan,
      sceneJson: sceneJson,
      sourceFiles: _sourceFiles(dir),
      issues: issues,
      legacy: legacy,
    );
  }

  Future<void> writeSpec(String name, CreativeSpec spec) async {
    final Directory dir = projectDir(name);
    _atomicWrite(
      File('${dir.path}/${ThreeWorkspaceLayout.specFile}'),
      _pretty(spec.toJson()),
    );
  }

  Future<void> writePlan(String name, CreativePlan3d plan) async {
    final Directory dir = projectDir(name);
    final ThreePlanValidation validation = validateThreePlan(plan.toJson());
    if (!validation.ok) {
      throw ThreeWorkspaceFailure(
        'plan_invalid',
        validation.fixHints.join('；'),
      );
    }
    _atomicWrite(
      File('${dir.path}/${ThreeWorkspaceLayout.planFile}'),
      _pretty(plan.toJson()),
    );
  }

  Future<void> writeScene(String name, Map<String, Object?> scene) async {
    final Directory dir = projectDir(name);
    _atomicWrite(
      File('${dir.path}/${ThreeWorkspaceLayout.sceneFile}'),
      _pretty(scene),
    );
  }

  Future<void> writeSource(
    String name,
    String relativePath,
    String code,
  ) async {
    if (!creativeIsSafeRelativePath(relativePath) ||
        !relativePath.endsWith('.js')) {
      throw const ThreeWorkspaceFailure('invalid_path');
    }
    final Directory dir = projectDir(name);
    final File file = File(
      '${dir.path}/${ThreeWorkspaceLayout.srcDir}/$relativePath',
    );
    file.parent.createSync(recursive: true);
    _atomicWrite(file, code);
  }

  Future<void> writeArtifact(
    String name,
    String relativePath,
    Object? jsonOrText,
  ) async {
    if (!creativeIsSafeRelativePath(relativePath)) {
      throw const ThreeWorkspaceFailure('invalid_path');
    }
    final Directory dir = projectDir(name);
    final File file = File(
      '${dir.path}/${ThreeWorkspaceLayout.artifactsDir}/$relativePath',
    );
    file.parent.createSync(recursive: true);
    _atomicWrite(file, jsonOrText is String ? jsonOrText : _pretty(jsonOrText));
  }

  /// 旧布局 → v2：写 spec/plan/src + migration.json，旧文件原样保留。
  Future<ThreeMigrationResult> migrateLegacy(String name) async {
    final Directory dir = projectDir(name);
    if (!dir.existsSync()) throw ThreeWorkspaceFailure('no_project', name);
    if (File('${dir.path}/${ThreeWorkspaceLayout.specFile}').existsSync()) {
      return ThreeMigrationResult(
        name: name,
        alreadyMigrated: true,
        wroteSpec: false,
        wrotePlan: false,
        copiedScene: false,
        planWarnings: const <String>[],
        mode: _modeOf(dir),
      );
    }
    final File legacySpec = File(
      '${dir.path}/${ThreeWorkspaceLayout.legacySpecFile}',
    );
    final File legacyState = File(
      '${dir.path}/${ThreeWorkspaceLayout.legacyStateFile}',
    );
    final File legacyScene = File(
      '${dir.path}/${ThreeWorkspaceLayout.legacySceneFile}',
    );
    if (!legacySpec.existsSync()) {
      throw const ThreeWorkspaceFailure('no_legacy', '缺 three-spec.json，无法迁移');
    }
    final Map<String, Object?> rawSpec;
    try {
      final Object? decoded = jsonDecode(legacySpec.readAsStringSync());
      if (decoded is! Map) throw const FormatException('not an object');
      rawSpec = Map<String, Object?>.from(decoded);
    } catch (error) {
      throw ThreeWorkspaceFailure('legacy_spec_invalid', '$error');
    }

    final List<String> acceptance = rawSpec['acceptance'] is List
        ? (rawSpec['acceptance'] as List)
              .map((item) => item.toString())
              .toList(growable: false)
        : const <String>[];
    final String prompt =
        (rawSpec['summary'] ?? rawSpec['title'] ?? '迁移自旧规范的 3D 场景').toString();
    final CreativeSpec spec = CreativeSpec(
      kind: CreativeKind.threeD,
      track: CreativeTrack.staticObject,
      prompt: prompt.trim().isEmpty ? '迁移自旧规范的 3D 场景' : prompt.trim(),
      mustHave: acceptance,
      style: const CreativeStyle(),
      output: const CreativeOutput(export: CreativeExportFormat.glb),
      extra: const <String, Object?>{'migrated_from': 'three-spec.json'},
    );
    final Map<String, Object?> draftJson = draftPlanFromLegacySpec(rawSpec);
    final ThreePlanValidation validation = validateThreePlan(draftJson);
    final CreativePlan3d? draft = validation.plan;
    if (draft == null) {
      throw ThreeWorkspaceFailure(
        'plan_invalid',
        validation.allIssues
            .map((issue) => '${issue.code}: ${issue.message}')
            .join('；'),
      );
    }
    dir.createSync(recursive: true);
    _atomicWrite(
      File('${dir.path}/${ThreeWorkspaceLayout.specFile}'),
      _pretty(spec.toJson()),
    );
    _atomicWrite(
      File('${dir.path}/${ThreeWorkspaceLayout.planFile}'),
      _pretty(draft.toJson()),
    );
    bool copiedScene = false;
    if (legacyScene.existsSync()) {
      final Directory src = Directory(
        '${dir.path}/${ThreeWorkspaceLayout.srcDir}',
      )..createSync(recursive: true);
      File('${src.path}/scene.js')
          .writeAsStringSync(legacyScene.readAsStringSync(), flush: true);
      copiedScene = true;
    }
    final Map<String, Object?> manifest = <String, Object?>{
      'v': 1,
      'from': 'legacy-three-service',
      'mode': ThreeAuthoringMode.code.name,
      'migrated_at': DateTime.now().toUtc().toIso8601String(),
      'legacy': <String, Object?>{
        'three_spec': true,
        'scene_js': legacyScene.existsSync(),
        'build_state': legacyState.existsSync(),
      },
      'notes': '旧文件保留；plan.json 是迁移草案，dims 来自 size_scale，需补精确尺寸',
    };
    String? legacyStateArtifact;
    if (legacyState.existsSync()) {
      final Directory artifacts = Directory(
        '${dir.path}/${ThreeWorkspaceLayout.artifactsDir}',
      )..createSync(recursive: true);
      final File target = File('${artifacts.path}/legacy-build-state.json');
      target.writeAsStringSync(legacyState.readAsStringSync(), flush: true);
      legacyStateArtifact =
          '${ThreeWorkspaceLayout.artifactsDir}/legacy-build-state.json';
    }
    if (legacyStateArtifact != null) {
      manifest['legacy_state_artifact'] = legacyStateArtifact;
    }
    _atomicWrite(
      File('${dir.path}/${ThreeWorkspaceLayout.migrationFile}'),
      _pretty(manifest),
    );
    return ThreeMigrationResult(
      name: name,
      alreadyMigrated: false,
      wroteSpec: true,
      wrotePlan: true,
      copiedScene: copiedScene,
      planWarnings: validation.allIssues
          .map((issue) => issue.message)
          .toList(growable: false),
    );
  }

  ThreeAuthoringMode _modeOf(Directory dir) {
    final bool hasScene = File('${dir.path}/${ThreeWorkspaceLayout.sceneFile}')
        .existsSync();
    final Directory src = Directory(
      '${dir.path}/${ThreeWorkspaceLayout.srcDir}',
    );
    final bool hasCode =
        src.existsSync() &&
        src
            .listSync(recursive: true)
            .whereType<File>()
            .any((file) => file.path.endsWith('.js'));
    if (hasCode) return ThreeAuthoringMode.code;
    if (hasScene) return ThreeAuthoringMode.scene;
    return ThreeAuthoringMode.code;
  }

  List<String> _sourceFiles(Directory dir) {
    final Directory src = Directory(
      '${dir.path}/${ThreeWorkspaceLayout.srcDir}',
    );
    if (!src.existsSync()) return const <String>[];
    final String prefix = '${src.path}/';
    return src
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.js'))
        .map(
          (file) => file.path.startsWith(prefix)
              ? file.path.substring(prefix.length)
              : file.path,
        )
        .toList(growable: false)
      ..sort();
  }

  static Object? _readJsonFile(File file) {
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  static String _pretty(Object? value) {
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert(value)}\n';
  }

  static void _atomicWrite(File file, String content) {
    file.parent.createSync(recursive: true);
    final File tmp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    tmp.writeAsStringSync(content, flush: true);
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(file.path);
  }
}
