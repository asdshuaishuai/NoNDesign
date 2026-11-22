// Local project library contract (batch 03).
//
// Covers the three layers the old server used to provide:
//  * project notes embedded in the source document (comments, escaping,
//    defaults for damaged payloads) and byte-compatibility with the
//    reference writer (golden file produced by the Python/Rust authority);
//  * save / open / list semantics: `file_not_found`, `need_password`,
//    automatic parent creation, `.ddp` suffix handling, newest-first order,
//    atomic replacement and no temp-file leftovers;
//  * storage roots: mobile projects live under the platform documents
//    directory (path_provider), never `systemTemp`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/project_service.dart';

Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

File _fixture(String name) => File('${_packageRoot().path}/test/fixtures/ddp/$name');

const _goldenDocs = {
  'prd': '# 需求\n\n按钮 2–4 字，正文对比度 ≥ 4.5。\n',
  'ui': '首页：一句话起步。\n',
};

void main() {
  group('project notes inside the source document', () {
    test('matches the reference writer byte-for-byte (golden)', () {
      final docs = <String, dynamic>{
        ..._goldenDocs,
        'design': defaultProjectDesign,
      };
      final produced = withProjectMetadata('DOC-BODY\n', docs);
      expect(produced, _fixture('docs_with_metadata.golden.txt').readAsStringSync());
    });

    test('comments come last and never contain a literal closing marker', () {
      final docs = <String, dynamic>{
        'prd': 'a --> b',
        'ui': 'x > y',
        'design': defaultProjectDesign,
      };
      final result = withProjectMetadata('BODY\n', docs);
      final lines = result.split('\n');
      final commentLines = lines.where((l) => l.startsWith('<!-- nondesign:')).toList();
      expect(commentLines, hasLength(2));
      expect(commentLines.first, startsWith('<!-- nondesign:design '));
      expect(commentLines.last, startsWith('<!-- nondesign:docs '));
      expect(result, isNot(contains('a --> b')));
      expect(result, contains(r'a --\u003e b'));
      expect(result, contains(r'x \u003e y'));
    });

    test('round-trips notes, unicode and newlines', () {
      final docs = <String, dynamic>{
        'prd': '# 需求\n\n第二行 “引号” & <tag>。\n',
        'ui': '说明：一\n二\n',
        'design': {
          ...defaultProjectDesign,
          'palette': {'primary': '#112233'},
          'rules': ['自定义规则'],
          'notes': '备注',
        },
      };
      final document = withProjectMetadata('BODY\n', docs);
      final parsed = parseProjectMetadata(document);
      expect(parsed['prd'], docs['prd']);
      expect(parsed['ui'], docs['ui']);
      final design = parsed['design'] as Map<String, dynamic>;
      expect((design['palette'] as Map)['primary'], '#112233');
      expect((design['palette'] as Map)['background'], '#F7F8FA');
      expect(design['rules'], ['自定义规则']);
      expect(design['notes'], '备注');
    });

    test('strip removes both comments and tidies blank runs', () {
      final document = withProjectMetadata('A\n\n\n\nB\n', {
        'prd': 'p',
        'ui': 'u',
        'design': defaultProjectDesign,
      });
      expect(stripProjectMetadata(document), 'A\n\nB');
    });

    test('damaged comments fall back to defaults instead of failing open', () {
      final parsed = parseProjectMetadata(
        'BODY\n<!-- nondesign:design {not json} -->\n'
        '<!-- nondesign:docs {"prd":5,"ui":"ok"} -->\n',
      );
      expect(parsed['prd'], '');
      expect(parsed['ui'], 'ok');
      expect(parsed['design'], defaultProjectDesign);
      expect(
        (parseProjectMetadata('BODY\n<!-- nondesign:design {not json} -->')['design']
            as Map)['v'],
        1,
      );
    });

    test('default notes are fresh copies (no shared mutable state)', () {
      final first = defaultProjectDocs();
      (first['design'] as Map<String, dynamic>)['notes'] = 'mutated';
      (first['design'] as Map<String, dynamic>)['rules'] = const [];
      final second = defaultProjectDocs();
      expect((second['design'] as Map)['notes'], '');
      expect((second['design'] as Map)['rules'], defaultProjectDesign['rules']);
    });

    test('design normalization merges types like the reference', () {
      final design = normalizeProjectDesign({
        'palette': {'primary': '#000000'},
        'spacing': [2, 3.7, 'x'],
        'rules': [1, 'a'],
        'notes': 5,
      });
      expect((design['palette'] as Map)['primary'], '#000000');
      expect((design['palette'] as Map)['background'], '#F7F8FA');
      expect(design['spacing'], [2, 3]);
      expect(design['rules'], ['1', 'a']);
      expect(design['notes'], '');
      expect(design['v'], 1);
      expect(normalizeProjectDesign(null)['palette'], defaultProjectDesign['palette']);
    });
  });

  group('save / open', () {
    late Directory root;
    late ProjectService service;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ddp_project_test_');
      service = ProjectService(root: () async => root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('creates parent directories and appends .ddp', () async {
      final path = '${root.path}/nested/deeper/project';
      final saved = await service.save(path: path, mbt: '# 画板\n');
      expect(saved.ok, isTrue, reason: saved.error);
      expect(saved.path, endsWith('project.ddp'));
      expect(File(saved.path!).existsSync(), isTrue);
      expect(saved.bytes, File(saved.path!).lengthSync());
    });

    test('replaces a non-.ddp extension like the reference writer', () async {
      final saved = await service.save(path: '${root.path}/note.txt', mbt: 'DOC');
      expect(saved.path, '${root.path}/note.ddp');
      expect(File('${root.path}/note.txt').existsSync(), isFalse);

      final upper = await service.save(path: '${root.path}/UPPER.DDP', mbt: 'DOC');
      expect(upper.path, '${root.path}/UPPER.DDP');
    });

    test('trailing separators are dropped before adding .ddp', () async {
      final saved = await service.save(path: '${root.path}/trail/', mbt: 'DOC');
      expect(saved.path, '${root.path}/trail.ddp');
      expect(File(saved.path!).existsSync(), isTrue);
    });

    test('without notes the source is stored verbatim', () async {
      final saved = await service.save(path: '${root.path}/plain', mbt: '# 画板\n\n内容\n');
      final opened = await service.open(saved.path!);
      expect(opened.ok, isTrue);
      expect(opened.mbt, '# 画板\n\n内容\n');
      expect(opened.docs, defaultProjectDocs());
    });

    test('notes round-trip through the container', () async {
      final saved = await service.save(
        path: '${root.path}/with_docs',
        mbt: '# 画板\n',
        docs: {
          'prd': '# PRD\n正文',
          'ui': '',
          'design': defaultProjectDesign,
        },
      );
      final opened = await service.open(saved.path!);
      expect(opened.ok, isTrue);
      expect(opened.docs!['prd'], '# PRD\n正文');
      expect(opened.mbt, contains('<!-- nondesign:docs '));
      final parsed = service.parseDocs(opened.mbt!);
      expect(parsed['prd'], '# PRD\n正文');
    });

    test('password-protected projects ask for the password and reject wrong ones', () async {
      final saved = await service.save(
        path: '${root.path}/locked',
        mbt: 'SECRET',
        password: 'correct horse',
        docs: const {},
      );
      expect(saved.ok, isTrue);

      final noPassword = await service.open(saved.path!);
      expect(noPassword.ok, isFalse);
      expect(noPassword.needPassword, isTrue);
      expect(noPassword.error, 'ddp_password_required');

      final wrong = await service.open(saved.path!, password: 'wrong');
      expect(wrong.needPassword, isTrue);
      expect(wrong.error, 'ddp_authentication_failed');

      final right = await service.open(saved.path!, password: 'correct horse');
      expect(right.ok, isTrue);
      expect(right.mbt, 'SECRET');
    });

    test('missing files report file_not_found', () async {
      final opened = await service.open('${root.path}/nope.ddp');
      expect(opened.ok, isFalse);
      expect(opened.error, 'file_not_found');
    });

    test('saving twice replaces the file and leaves no temp leftovers', () async {
      final first = await service.save(path: '${root.path}/twice', mbt: 'FIRST');
      final second = await service.save(path: '${root.path}/twice', mbt: 'SECOND');
      expect(second.bytes, greaterThan(0));
      expect((await service.open(first.path!)).mbt, 'SECOND');
      final leftovers = root
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((name) => name.contains('.tmp-'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('a path that is a directory fails without destroying anything', () async {
      final dir = Directory('${root.path}/as_dir.ddp')..createSync();
      final saved = await service.save(path: dir.path, mbt: 'DOC');
      expect(saved.ok, isFalse);
      expect(saved.error, 'ddp_write_failed');
      expect(dir.existsSync(), isTrue);
    });
  });

  group('list', () {
    late Directory root;
    late ProjectService service;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ddp_list_test_');
      service = ProjectService(root: () async => root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('lists .ddp files newest first with name/path/bytes/modified', () async {
      final oldest = File('${root.path}/oldest.ddp')..writeAsStringSync('a');
      final middle = File('${root.path}/middle.ddp')..writeAsStringSync('bb');
      final newest = File('${root.path}/newest.ddp')..writeAsStringSync('ccc');
      File('${root.path}/readme.txt').writeAsStringSync('not a project');
      Directory('${root.path}/folder.ddp').createSync();

      final now = DateTime.now();
      oldest.setLastModifiedSync(now.subtract(const Duration(hours: 2)));
      middle.setLastModifiedSync(now.subtract(const Duration(hours: 1)));
      newest.setLastModifiedSync(now);

      final listed = await service.list();
      expect(listed.ok, isTrue, reason: listed.error);
      expect(listed.projects.map((e) => e.name), ['newest', 'middle', 'oldest']);
      final first = listed.projects.first;
      // Windows 上目录扫描返回 `\` 分隔的绝对路径，夹具用 `/` 拼接；
      // 只比较语义路径，不把平台分隔符写进断言。
      String norm(String path) => path.replaceAll('\\', '/');
      expect(norm(first.path), norm(newest.path));
      expect(first.bytes, 3);
      expect(first.modified, closeTo(now.millisecondsSinceEpoch / 1000.0, 2.0));
      expect(first.toJson().keys, containsAll(['path', 'name', 'bytes', 'modified']));
      expect(listed.projects.map((e) => e.name), isNot(contains('readme')));
      expect(listed.projects.map((e) => e.name), isNot(contains('folder')));
    });

    test('default root is created on demand', () async {
      final missing = Directory('${root.path}/library');
      final local = ProjectService(root: () async => missing);
      final listed = await local.list();
      expect(listed.ok, isTrue);
      expect(missing.existsSync(), isTrue);
    });

    test('an explicit missing directory reports dir_not_found and is not created', () async {
      final target = '${root.path}/typo';
      final listed = await service.list(dir: target);
      expect(listed.ok, isFalse);
      expect(listed.error, 'dir_not_found');
      expect(Directory(target).existsSync(), isFalse);
    });

    test('explicit directories are listed without creating anything', () async {
      final other = Directory('${root.path}/other')..createSync();
      File('${other.path}/x.ddp').writeAsStringSync('x');
      final listed = await service.list(dir: other.path);
      expect(listed.ok, isTrue);
      expect(listed.projects.single.name, 'x');
    });
  });

  group('AppPaths', () {
    tearDown(() {
      AppPaths.projectsRootOverride = null;
      AppPaths.documentsDirectoryOverride = null;
      AppPaths.rootOverride = null;
    });

    test('mobile projects live under the platform documents directory', () async {
      final docs = Directory.systemTemp.createTempSync('app_docs_test_');
      AppPaths.documentsDirectoryOverride = docs;
      final projects = await AppPaths.projectsRoot();
      expect(projects.path, '${docs.path}/${AppPaths.projectsDirName}');
      expect(projects.existsSync(), isTrue);
      docs.deleteSync(recursive: true);
    });

    test('explicit projects root override wins', () async {
      final custom = Directory.systemTemp.createTempSync('projects_override_');
      AppPaths.projectsRootOverride = custom;
      expect((await AppPaths.projectsRoot()).path, custom.path);
      custom.deleteSync(recursive: true);
    });

    test('desktop projects live in ~/Documents/NoNDesign', () {
      expect(
        AppPaths.desktopProjectsDir('/Users/example'),
        '/Users/example/Documents/NoNDesign',
      );
    });

    test('project root is wired to path_provider, not systemTemp', () {
      final source = File('${_packageRoot().path}/lib/core/app_paths.dart').readAsStringSync();
      expect(source, contains("package:path_provider/path_provider.dart"));
      final start = source.indexOf('static Future<Directory> projectsRoot()');
      expect(start, greaterThan(-1));
      final end = source.indexOf('static Directory dataRoot()', start);
      final projectsRoot = source.substring(start, end);
      expect(projectsRoot, contains('appDocumentsDirectory'));
      expect(projectsRoot, isNot(contains('systemTemp')));
    });

    test('~ expands to the current home directory', () {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;
      expect(expandProjectPath('~/proj.ddp'), startsWith(home));
      expect(expandProjectPath('~'), home);
      expect(expandProjectPath('/tmp/proj.ddp'), '/tmp/proj.ddp');
    });
  });
}
