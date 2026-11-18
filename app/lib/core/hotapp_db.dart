/// 热应用的本地数据面：每应用一个 SQLite 数据库 + 页面侧 JS 通道。
///
/// 背景（批次 07）：过去热应用的持久化依赖外部服务注入的桥脚本，离线打开
/// 时直接降级成「不能保存」。现在应用自己的数据落本机 SQLite：
///
///   <应用目录>/app.db       每个热应用独立（导入 = 全新实例，数据不随包走）
///   window.NoN.db.exec()    页面侧唯一入口（返回 Promise）
///   NONHOTDB                页面 ↔ 宿主的通道名（桥脚本由宿主注入）
///
/// 三条边界：
///  1. **不受信页面只能碰自己的库**。SQL 门（[hotAppSqlRejectReason]）只放行
///     单条 DDL/DML/查询，ATTACH / VACUUM INTO / load_extension 等能读写任意
///     文件的能力一律拒绝——包是不可信输入，桥不能变成文件系统后门。
///  2. **有界**：单次 SQL、返回行数、返回体积都有上限，页面脚本不能把宿主
///     拖进无界内存。
///  3. **诚实降级**：数据库打不开（平台不支持/磁盘满）时桥返回
///     `{ok:false}`，页面可以显示自己的提示；宿主侧的横幅由工作台负责。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'nonapp_package.dart';

/// 每个热应用的数据文件名。
const String hotAppDbFileName = 'app.db';

/// 页面侧 JS 通道名（与桥脚本同字面量，改一处必须改两处）。
const String hotAppDbChannel = 'NONHOTDB';

/// 页面运行错误通道名（window.onerror / unhandledrejection → 宿主）。
const String hotAppPageErrorChannel = 'NONHOTAPP';

/// 宿主回填结果的全局函数名。
const String hotAppDbResultFunction = '__NoNDbResult';

/// 单次 SQL 文本上限（64 KiB）：页面一次执行的语句不该超过这个量级。
const int hotAppDbMaxSqlBytes = 64 * 1024;

/// 单次返回的最大行数。
const int hotAppDbMaxRows = 500;

/// 单次返回 JSON 的体积上限（1 MiB），超出即截断并标记。
const int hotAppDbMaxResultBytes = 1024 * 1024;

/// 参数个数上限（防止构造超大绑定数组）。
const int hotAppDbMaxParams = 128;

/// 单次 blob 生成函数（randomblob / zeroblob）的上限：超过这个体积的
/// 字面量调用一律拒绝，避免一次调用让宿主分配 GB 级内存。
const int hotAppDbMaxBlobBytes = 64 * 1024;

/// 进程内 SQLite 堆上限（256 MiB）。即使门漏过某种吃内存的语句，
/// SQLite 也只会返回 NOMEM，而不是把整个应用拖进 OOM。
const int hotAppDbHeapLimitBytes = 256 * 1024 * 1024;

/// 数据库失败（内部代号；界面用 [hotAppDbFailureMessage] 翻成人话）。
class HotAppDbFailure implements Exception {
  const HotAppDbFailure(this.code, this.detail);

  /// 内部代号，只进日志与技术详情。
  final String code;

  /// 原始诊断（永不上屏）。
  final String detail;

  @override
  String toString() => '$code: $detail';
}

/// 把内部失败翻成一句用户能懂的话（原始诊断留给折叠的技术详情）。
String hotAppDbFailureMessage(HotAppDbFailure? failure) {
  switch (failure?.code) {
    case 'db_unavailable':
      return '这个应用的数据暂时无法保存';
    case 'db_sql_rejected':
      return '应用的数据操作没有被接受';
    case 'db_busy':
      return '应用的数据暂时被占用，请稍后再试';
    case 'db_result_too_large':
      return '应用返回的数据太多，已截断';
    default:
      return '应用的数据操作没有完成，请重试';
  }
}

/// SQL 静态门：返回 null = 放行，否则是被拒原因（内部标签）。
///
/// 纯函数（不碰 sqlite），单测直接锚定。规则：
///  * 只允许单条语句（不允许分号，末尾分号会被先剥掉）；
///  * 首关键字白名单：select / with / pragma / insert / replace / update /
///    delete / create / drop / alter；
///  * 任何位置出现 attach / detach / vacuum / load_extension / 可写 schema /
///    文件系统相关 pragma 一律拒绝。
String? hotAppSqlRejectReason(String sql) {
  var text = sql.trim();
  if (text.isEmpty) return 'empty';
  // 去掉末尾分号（单条语句的常见写法），内部还有分号 = 多语句。
  while (text.endsWith(';')) {
    text = text.substring(0, text.length - 1).trimRight();
  }
  if (text.isEmpty) return 'empty';

  // 去掉注释后再看关键字：`/*x*/ attach` 不能绕过首关键字白名单。
  final stripped = text
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'--[^\n]*'), ' ')
      .trim();
  if (stripped.contains(';')) return 'multiple_statements';

  final lower = stripped.toLowerCase();
  final first = RegExp(r'^[a-z]+').firstMatch(lower)?.group(0) ?? '';
  const allowed = {
    'select',
    'with',
    'pragma',
    'insert',
    'replace',
    'update',
    'delete',
    'create',
    'drop',
    'alter',
  };
  if (!allowed.contains(first)) return 'statement_not_allowed:$first';

  final banned = <RegExp, String>{
    RegExp(r'\battach\b'): 'attach',
    RegExp(r'\bdetach\b'): 'detach',
    RegExp(r'\bvacuum\b'): 'vacuum',
    RegExp(r'\bload_extension\b'): 'load_extension',
    RegExp(r'\bwritable_schema\b'): 'writable_schema',
    // 页面不能关掉宿主设置的堆上限（否则 OOM 防护被一条 PRAGMA 解除）。
    RegExp(r'\bhard_heap_limit\b'): 'hard_heap_limit',
    RegExp(r'\bsoft_heap_limit\b'): 'soft_heap_limit',
    RegExp(r'\btemp_store_directory\b'): 'temp_store_directory',
    RegExp(r'\bdata_store_directory\b'): 'data_store_directory',
    RegExp(r'\bwritefile\b'): 'writefile',
    RegExp(r'\breadfile\b'): 'readfile',
  };
  for (final entry in banned.entries) {
    if (entry.key.hasMatch(lower)) return 'keyword_not_allowed:${entry.value}';
  }
  // 无界递归 CTE 是「一次调用冻结宿主」的最短路径：页面脚本能写
  // `WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c)`，
  // 结果集没有上限。只读查询不允许递归；需要层级查询的应用应自己带深度条件。
  if (RegExp(r'\bwith\s+recursive\b').hasMatch(lower)) {
    return 'recursive_cte_not_allowed';
  }
  // blob 生成函数按字面量体积门控；参数化/表达式一律拒绝（运行时才知道
  // 大小，宿主不能先分配再判断）。
  for (final match in RegExp(r'\b(?:randomblob|zeroblob)\s*\(\s*([^)]*)\)').allMatches(lower)) {
    final arg = match.group(1)?.trim() ?? '';
    final size = int.tryParse(arg);
    if (size == null || size < 0 || size > hotAppDbMaxBlobBytes) {
      return 'blob_too_large';
    }
  }
  return null;
}

/// 一个热应用的数据库句柄。
///
/// 同步 API（sqlite3 本身同步）；页面桥在宿主侧串行调用，不跨 isolate。
class HotAppDb {
  HotAppDb._(this._db, this.path);

  final Database _db;

  /// 数据库文件绝对路径。
  final String path;

  /// 打开（必要时创建）[appDir] 下的应用数据库。
  ///
  /// 目录不存在时创建；文件损坏/不可写抛 [HotAppDbFailure]。
  static HotAppDb openForApp(String appDir) {
    final dir = Directory(appDir);
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (error) {
      throw HotAppDbFailure('db_unavailable', '$error');
    }
    final path = '${dir.path}/$hotAppDbFileName';
    try {
      final db = sqlite3.open(path);
      // 页面可能与宿主短暂并发（连点）：给一点等待而不是立刻 SQLITE_BUSY。
      db.execute('PRAGMA busy_timeout = 1500');
      db.execute('PRAGMA foreign_keys = ON');
      // 进程级 SQLite 堆上限：门漏过的吃内存语句最多得到 SQLITE_NOMEM，
      // 不会把整个应用拖进 GB 级分配/OOM。
      db.execute('PRAGMA hard_heap_limit = $hotAppDbHeapLimitBytes');
      return HotAppDb._(db, path);
    } on SqliteException catch (error) {
      throw HotAppDbFailure('db_unavailable', '$error');
    } catch (error) {
      throw HotAppDbFailure('db_unavailable', '$error');
    }
  }

  /// 执行一条语句/查询。
  ///
  /// 返回 [hotAppDbMaxResultBytes] 有界的 JSON 形状：
  /// `{ok, rows, changes, last_insert_rowid, truncated}`。
  /// 失败抛 [HotAppDbFailure]。
  Map<String, dynamic> exec(String sql, [List<Object?> params = const []]) {
    final reason = hotAppSqlRejectReason(sql);
    if (reason != null) throw HotAppDbFailure('db_sql_rejected', reason);
    if (sql.codeUnits.length > hotAppDbMaxSqlBytes) {
      throw const HotAppDbFailure('db_sql_rejected', 'sql_too_large');
    }
    if (params.length > hotAppDbMaxParams) {
      throw const HotAppDbFailure('db_sql_rejected', 'too_many_params');
    }

    final read = _isReadStatement(sql);
    try {
      if (read) {
        // 行数上限要在 SQLite 物化之前生效：包一层 LIMIT，避免先取回
        // 百万行再在 Dart 侧截断。PRAGMA/EXPLAIN 不包（语法不允许）。
        final rows = _db.select(_boundedReadSql(sql), params);
        final encoded = <Map<String, dynamic>>[];
        var bytes = 0;
        var truncated = false;
        for (final row in rows) {
          if (encoded.length >= hotAppDbMaxRows) {
            truncated = true;
            break;
          }
          final map = <String, dynamic>{};
          for (final key in row.keys) {
            map[key] = _encodeValue(row[key]);
          }
          final size = jsonEncode(map).length;
          if (bytes + size > hotAppDbMaxResultBytes) {
            truncated = true;
            break;
          }
          bytes += size;
          encoded.add(map);
        }
        return {
          'ok': true,
          'rows': encoded,
          'changes': 0,
          'last_insert_rowid': _db.lastInsertRowId,
          if (truncated) 'truncated': true,
        };
      }
      _db.execute(sql, params);
      return {
        'ok': true,
        'rows': const <Map<String, dynamic>>[],
        'changes': _db.updatedRows,
        'last_insert_rowid': _db.lastInsertRowId,
      };
    } on SqliteException catch (error) {
      // busy/locked 单独给一句「稍后重试」；其余保持通用失败。
      final message = error.message.toLowerCase();
      if (message.contains('busy') || message.contains('locked')) {
        throw HotAppDbFailure('db_busy', '$error');
      }
      throw HotAppDbFailure('db_sql_rejected', '$error');
    } catch (error) {
      throw HotAppDbFailure('db_unavailable', '$error');
    }
  }

  /// 关闭句柄（应用切换/工作台销毁时调用）。
  void dispose() {
    try {
      _db.close();
    } catch (_) {
      // 已关闭/底层异常：dispose 失败不改变任何用户可见状态。
    }
  }
}

bool _isReadStatement(String sql) {
  final text = sql
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'--[^\n]*'), ' ')
      .trimLeft()
      .toLowerCase();
  if (text.startsWith('pragma')) return true;
  if (text.startsWith('select') || text.startsWith('explain')) return true;
  if (text.startsWith('with')) {
    // WITH … SELECT 是查询；WITH … INSERT/UPDATE/DELETE 由 execute 处理。
    final tail = text.substring(4);
    return !(RegExp(r'\b(insert|update|delete|replace)\b').hasMatch(tail));
  }
  return false;
}

/// 给 SELECT/WITH 查询加上服务端行数上限。
///
/// SQLite 的 `select` API 会先把整个结果集物化；只在 Dart 侧数到 500 行
/// 已经太晚。包一层子查询 + LIMIT 后，常见的行爆炸在 SQLite 内部就停住。
String _boundedReadSql(String sql) {
  final text = sql.trim().replaceFirst(RegExp(r';+\s*$'), '');
  final lower = text.toLowerCase();
  if (lower.startsWith('select') || lower.startsWith('with')) {
    return 'SELECT * FROM ($text) LIMIT ${hotAppDbMaxRows + 1}';
  }
  return text;
}

Object? _encodeValue(Object? value) {
  // 非有限浮点（inf/nan）无法进 JSON：转字符串，别让整条应答编码失败。
  if (value is double && !value.isFinite) return value.toString();
  if (value == null || value is num || value is String) return value;
  // sqlite3 3.x 的 BLOB 列以 Uint8List 返回；JSON 不携带二进制，转 base64。
  if (value is Uint8List) return {'base64': base64Encode(value)};
  return value.toString();
}

/// 注入到预览页的桥脚本：定义 `window.NoN.db.exec`。
///
/// 只做「发一条消息、等宿主回填」：不做校验、不碰存储——安全边界全在宿主。
/// 页面拿到的 Promise 总是 resolve（失败也是 `{ok:false}`），页面不必写
/// try/catch 也能显示自己的错误态。
const String hotAppDbBridgeScript = '''
(function () {
  if (window.NoN && window.NoN.db) return;
  var seq = 0;
  var pending = {};
  window.$hotAppDbResultFunction = function (id, payload) {
    var fn = pending[id];
    if (!fn) return;
    delete pending[id];
    fn(payload);
  };
  function reportError(message) {
    try {
      window.$hotAppPageErrorChannel.postMessage(JSON.stringify({ kind: 'error', message: String(message || 'unknown') }));
    } catch (e) {}
  }
  window.addEventListener('error', function (event) {
    reportError(event && (event.message || event.error));
  });
  window.addEventListener('unhandledrejection', function (event) {
    reportError(event && event.reason);
  });
  window.NoN = window.NoN || {};
  window.NoN.db = {
    exec: function (input) {
      var sql = typeof input === 'string' ? input : ((input && input.sql) || '');
      var params = (input && input.params) || [];
      var id = 'q' + (++seq);
      return new Promise(function (resolve) {
        pending[id] = resolve;
        try {
          window.$hotAppDbChannel.postMessage(JSON.stringify({ id: id, sql: sql, params: params }));
        } catch (e) {
          delete pending[id];
          resolve({ ok: false, error: 'unavailable' });
        }
      });
    }
  };
})();
''';

/// 预览页注入：CSP meta（先） + 数据桥脚本（后、早于页面内容）。
///
/// 为什么必须分开注入而不是交给 `NonAppCache.writeHtml` 的 CSP：策略与桥都
/// 要在页面第一个脚本之前生效，且顺序不能反（先 CSP 再桥，否则桥脚本在策略
/// 生效前就已执行——虽然 CSP 本身也要靠 meta 生效，但「策略在前」是 review
/// nonapp-5 的锚点）。
String injectHotAppRuntime(String html) {
  final withCsp = injectNonAppCsp(html);
  final marker = '<meta http-equiv="Content-Security-Policy"';
  final idx = withCsp.indexOf(marker);
  if (idx >= 0) {
    final end = withCsp.indexOf('>', idx);
    if (end >= 0) {
      return withCsp.replaceRange(end + 1, end + 1, '<script>$hotAppDbBridgeScript</script>');
    }
  }
  final head = withCsp.toLowerCase().indexOf('<head');
  if (head >= 0) {
    final end = withCsp.indexOf('>', head);
    if (end >= 0) {
      return withCsp.replaceRange(end + 1, end + 1, '<script>$hotAppDbBridgeScript</script>');
    }
  }
  return '<script>$hotAppDbBridgeScript</script>$withCsp';
}
