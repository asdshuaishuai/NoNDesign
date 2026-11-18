/// 热应用的本地库（批次 07）：导入 / 生成都落到本机目录，作品集据此扫描。
///
/// 目录契约（一个应用一个目录，导入 = 全新实例）：
///
/// ```
/// <projectsRoot>/hotapps/<name>/
///   manifest.json      包清单（与 `.nonapp` 内的同形）
///   index.html         renderer=html 的载荷
///   surface.json       renderer=a2ui 的载荷（归一为数组）
///   data.json          可选 DataModel 快照
///   prompt.txt         可选续跑提示
///   app.db             应用自己的本地数据库（见 hotapp_db.dart）
/// ```
///
/// **manifest.json 是唯一事实源**：作品集扫描只看目录里的清单与载荷，不维护
/// 第二份索引（索引与目录会漂移；目录才是用户真正拥有的东西）。
///
/// 写入纪律：
///  * 先在同级临时目录里组装完整内容 → 校验 → `rename` 到目标名；
///  * 导入替换同名应用时先删旧目录（契约：导入 = 新实例，旧数据不继承）；
///  * 失败不留半成品目录。
///
/// `.nonapp` 包字节与目录内容互转：[buildPackage] 产出可被
/// [NonAppPackage.parse] 重新解析的 zip；不承诺 ZIP 容器逐字节一致
/// （时间戳/顺序由写者决定），只承诺语义互操作。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'app_paths.dart';
import 'hotapp_db.dart';
import 'nonapp_package.dart';

/// 本地库根目录名（`<projectsRoot>/hotapps`）。
const String nonAppLibraryDirName = 'hotapps';

/// 一个已安装的热应用（作品集/工作台共用的视图）。
class LibraryApp {
  const LibraryApp({
    required this.name,
    required this.title,
    required this.renderer,
    required this.createdAt,
    required this.dir,
    required this.payloadBytes,
    this.brief,
    this.corrupt = false,
  });

  /// 目录名 + manifest.name（ASCII snake/kebab；不可信字符串，拼 HTML 前必须转义）。
  final String name;
  final String title;

  /// `html` | `a2ui`。
  final String renderer;
  final int createdAt;

  /// 应用目录绝对路径。
  final String dir;

  /// 载荷字节数（html 文件大小 / surface JSON 大小）。
  final int payloadBytes;

  /// 生成时的原始需求（可选）。
  final String? brief;

  /// 清单/载荷读不出来（目录还在，但内容损坏）。
  final bool corrupt;

  bool get isA2ui => renderer == 'a2ui';

  /// 作品集货架条目（kind 与艺术架的 hotapp 类目一致）。
  Map<String, dynamic> toShelfItem() => {
        'kind': 'hotapp',
        'ref': name,
        'title': title,
        'detail': isA2ui ? '可交互应用' : '热应用',
        'path': isA2ui ? dir : '$dir/index.html',
        'renderer': renderer,
      };

  @override
  String toString() => 'LibraryApp($name, $renderer, $payloadBytes B)';
}

/// 本地热应用库。
class NonAppLibrary {
  NonAppLibrary({required this.root});

  /// 库根目录。
  final Directory root;

  /// 打开默认库：`<projectsRoot>/hotapps`。
  ///
  /// **不在这里建目录**：只读浏览（作品集/应用列表）不该在用户的文档目录
  /// 留下空壳；第一次安装时才 `create`。
  ///
  /// [root] 显式给定时不碰平台目录（测试/嵌入式宿主）。
  static Future<NonAppLibrary> open({Directory? root}) async {
    final dir = root ?? Directory('${(await AppPaths.projectsRoot()).path}/$nonAppLibraryDirName');
    return NonAppLibrary(root: dir);
  }

  /// 应用目录（**调用方必须先用 [isValidNonAppName] 校验 name**）。
  Directory appDir(String name) {
    if (!isValidNonAppName(name)) {
      throw NonAppException('nonapp_invalid_name:$name', '应用名非法，拒绝访问');
    }
    return Directory('${root.path}/$name');
  }

  /// 扫描全部应用（按创建时间倒序、再按名字）。
  ///
  /// 损坏的目录以 `corrupt: true` 出现——作品集可以显示「这个应用读不出来」
  /// 而不是静默消失（用户至少知道东西还在）。
  Future<List<LibraryApp>> scan() async {
    if (!root.existsSync()) return const [];
    final entries = <LibraryApp>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('.')) continue; // 临时安装目录
      if (!isValidNonAppName(name)) continue;
      final app = _readSync(name);
      if (app != null) entries.add(app);
    }
    entries.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : a.name.compareTo(b.name);
    });
    return entries;
  }

  /// 读单个应用（不存在返回 null）。
  Future<LibraryApp?> read(String name) async => _readSync(name);

  LibraryApp? _readSync(String name) {
    if (!isValidNonAppName(name)) return null;
    final dir = Directory('${root.path}/$name');
    if (!dir.existsSync()) return null;
    final manifestFile = File('${dir.path}/manifest.json');
    if (!manifestFile.existsSync()) return null;

    Map<String, dynamic>? manifest;
    try {
      final decoded = jsonDecode(manifestFile.readAsStringSync());
      if (decoded is Map) manifest = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (manifest == null) {
      return LibraryApp(
        name: name,
        title: name,
        renderer: 'html',
        createdAt: 0,
        dir: dir.path,
        payloadBytes: 0,
        corrupt: true,
      );
    }

    final renderer = (manifest['renderer'] ?? 'html').toString();
    final payload = File('${dir.path}/${renderer == 'a2ui' ? 'surface.json' : 'index.html'}');
    final exists = payload.existsSync();
    return LibraryApp(
      name: name,
      title: (manifest['title'] ?? manifest['name'] ?? name).toString(),
      renderer: renderer,
      createdAt: (manifest['createdAt'] is num) ? (manifest['createdAt'] as num).toInt() : 0,
      dir: dir.path,
      payloadBytes: exists ? payload.lengthSync() : 0,
      brief: manifest['brief']?.toString(),
      corrupt: !exists,
    );
  }

  /// 安装一个已解析的包（导入 / 生成共用）。
  ///
  /// html 载荷在落盘前再跑一次**离线门**（`assertHtmlOfflineSafe`）：包解析
  /// 只保证「服务端等价面」，而库里的文件会被 file:// 直接执行，必须更严。
  Future<LibraryApp> install(NonAppPackage pkg) async {
    final name = pkg.manifest.name;
    if (!isValidNonAppName(name)) {
      throw NonAppException('nonapp_invalid_name:$name', '应用名非法，拒绝安装');
    }
    if (pkg.renderer == 'html') {
      final html = pkg.htmlBytes;
      if (html == null) {
        throw const NonAppException('nonapp_missing_payload', '缺少页面内容');
      }
      assertHtmlOfflineSafe(utf8.decode(html));
    }

    if (!root.existsSync()) root.createSync(recursive: true);
    final temp = Directory('${root.path}/.install-$name-${DateTime.now().microsecondsSinceEpoch}');
    try {
      temp.createSync(recursive: true);
      File('${temp.path}/manifest.json')
          .writeAsStringSync(jsonEncode(pkg.manifest.toJson()), flush: true);
      if (pkg.renderer == 'html') {
        File('${temp.path}/index.html').writeAsBytesSync(pkg.htmlBytes!, flush: true);
      } else {
        File('${temp.path}/surface.json')
            .writeAsStringSync(jsonEncode(pkg.messages ?? const []), flush: true);
        if (pkg.data != null) {
          File('${temp.path}/data.json').writeAsStringSync(jsonEncode(pkg.data), flush: true);
        }
        if (pkg.prompt != null) {
          File('${temp.path}/prompt.txt').writeAsStringSync(pkg.prompt!, flush: true);
        }
      }
      // 每个应用一个数据库：安装即建库（页面桥不再自己碰路径）。
      // 建库失败不阻断安装：页面仍可运行，数据桥按「暂时无法保存」降级。
      try {
        HotAppDb.openForApp(temp.path).dispose();
      } catch (error) {
        // 这里不引 Flutter：核心层只留一行标准错误输出（诊断用）。
        // ignore: avoid_print
        print('[nonapp] app db unavailable: $error');
      }

      final target = Directory('${root.path}/$name');
      if (target.existsSync()) target.deleteSync(recursive: true);
      temp.renameSync(target.path);
      final installed = _readSync(name);
      if (installed == null || installed.corrupt) {
        throw const NonAppException('nonapp_install_failed', '安装后读不到应用内容');
      }
      return installed;
    } on NonAppException {
      _cleanup(temp);
      rethrow;
    } on FileSystemException catch (error) {
      _cleanup(temp);
      throw NonAppException('nonapp_install_failed', '写入应用目录失败：$error');
    } catch (error) {
      _cleanup(temp);
      throw NonAppException('nonapp_install_failed', '安装应用失败：$error');
    }
  }

  /// 把已安装应用打包成 `.nonapp` 字节（导出 / 分享）。
  Future<List<int>> buildPackage(String name) async {
    final dir = appDir(name);
    if (!dir.existsSync()) {
      throw NonAppException('nonapp_missing_app:$name', '这个应用已经不在了');
    }
    final manifestFile = File('${dir.path}/manifest.json');
    if (!manifestFile.existsSync()) {
      throw NonAppException('nonapp_missing_manifest:$name', '应用清单缺失');
    }
    final manifest = jsonDecode(manifestFile.readAsStringSync());
    if (manifest is! Map) {
      throw NonAppException('nonapp_invalid_manifest:$name', '应用清单读不出来');
    }
    final renderer = (manifest['renderer'] ?? 'html').toString();
    final payloadName = renderer == 'a2ui' ? 'payload/surface.json' : 'payload/index.html';
    final payload = File('${dir.path}/${renderer == 'a2ui' ? 'surface.json' : 'index.html'}');
    if (!payload.existsSync()) {
      throw NonAppException('nonapp_missing_payload:$name', '应用内容缺失');
    }

    final archive = Archive();
    void add(String entry, List<int> bytes) {
      archive.addFile(ArchiveFile(entry, bytes.length, bytes));
    }

    add('manifest.json', utf8.encode(jsonEncode(manifest)));
    add(payloadName, payload.readAsBytesSync());
    if (renderer == 'a2ui') {
      for (final extra in const [
        ('data.json', 'payload/data.json'),
        ('prompt.txt', 'payload/prompt.txt'),
      ]) {
        final file = File('${dir.path}/${extra.$1}');
        if (file.existsSync()) add(extra.$2, file.readAsBytesSync());
      }
    }
    final bytes = ZipEncoder().encode(archive);
    if (bytes.length > nonAppMaxPackageBytes) {
      throw const NonAppException('nonapp_too_large', '应用内容超过单包上限，无法导出');
    }
    return bytes;
  }

  /// 替换已安装应用的页面（精修/热更新路径）。
  ///
  /// 与 [install] 的差别：**不碰应用目录里的其他文件**——manifest 与
  /// app.db 原样保留（精修不得清空用户数据）。页面写入仍是临时文件 +
  /// rename 的原子替换：失败保留旧页面。
  Future<LibraryApp> replaceHtml(String name, Uint8List html) async {
    final dir = appDir(name);
    if (!dir.existsSync()) {
      throw NonAppException('nonapp_missing_app:$name', '这个应用已经不在了');
    }
    final htmlText = utf8.decode(html);
    assertHtmlOfflineSafe(htmlText);
    final target = File('${dir.path}/index.html');
    final tmp = File('${dir.path}/.index.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      tmp.writeAsBytesSync(html, flush: true);
      tmp.renameSync(target.path);
    } on FileSystemException catch (error) {
      _cleanupFile(tmp);
      throw NonAppException('nonapp_install_failed', '写入页面失败：$error');
    } catch (error) {
      _cleanupFile(tmp);
      throw NonAppException('nonapp_install_failed', '写入页面失败：$error');
    }
    final entry = _readSync(name);
    if (entry == null || entry.corrupt) {
      throw NonAppException('nonapp_missing_payload:$name', '写入后读不到应用内容');
    }
    return entry;
  }

  /// 删除应用（目录 + 数据库一起删，不可恢复）。
  Future<void> delete(String name) async {
    final dir = appDir(name);
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      throw NonAppException('nonapp_delete_failed', '删除应用失败：$error');
    }
  }

  /// html 载荷文本（不存在/损坏返回 null）。
  Future<String?> readHtml(String name) async {
    final dir = appDir(name);
    final file = File('${dir.path}/index.html');
    if (!file.existsSync()) return null;
    try {
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  /// a2ui 载荷消息序列（不存在/损坏返回 null）。
  Future<List<Object?>?> readSurface(String name) async {
    final dir = appDir(name);
    final file = File('${dir.path}/surface.json');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is List) return List<Object?>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// 应用数据库（工作台在挂载时打开，切走时 dispose）。
  HotAppDb openDb(String name) => HotAppDb.openForApp(appDir(name).path);

  void _cleanup(Directory temp) {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }

  void _cleanupFile(File temp) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } catch (_) {}
  }
}

/// 把任意字节流当作包安装（导入路径的便捷入口；解析失败抛 [NonAppException]）。
Future<LibraryApp> installNonAppBytes(
  NonAppLibrary library,
  Uint8List bytes, {
  String clientVersion = nonAppClientVersion,
}) async {
  final pkg = NonAppPackage.parse(bytes, clientVersion: clientVersion);
  return library.install(pkg);
}
