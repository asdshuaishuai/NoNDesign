/// 视频工作区的本地面（批次 08）。
///
/// 这一层把原先由本地服务承担的整条视频管线搬进客户端进程：
///
///  * **规范先行**（硬门 1）：时间线脚本必须携带一份规范（科学说明或剧本），
///    缺失、缺字段、参数不是数值都在渲染第一帧之前干净拒绝。
///  * **符号声明闭包**（硬门 2）：算式里出现的自定义名字必须来自
///    `params ∪ formulas`（外加内置 `t/T/pi/e` 与数学函数白名单）——“想当然”
///    的裸常数/裸坐标进不来，未声明即拒绝。
///  * **确定性逐帧渲染**：同 (脚本, 规范) 永远出同一片。所有算式在渲染开始前
///    一次性编译（语法/符号错误在第一帧之前报干净），每帧 SVG 由纯函数生成。
///  * **机械对照**：规范复检 + 符号闭包 + 节拍覆盖 + 故事板幕数提示，全部在
///    本地算，不依赖任何端口或内部路由。
///  * **渲染执行**：桌面用 [Process.run] 调 `resvg`（回退 `rsvg-convert`）出
///    逐帧 PNG，再调 `ffmpeg` 编码 mp4；手机/平板不能 spawn 进程，只保留
///    脚本编辑、机械对照与既有视频播放（[startRender] 会显式拒绝）。
///
/// 边界：
///  1. 本文件是**纯 Dart**（只依赖 dart:io/convert/math）——`scripts/wf`
///     的黄金对照工具可以用 `dart run` 直接驱动它，不需要 Flutter 绑定。
///  2. 用户可见文案不在这里拼：内部代号经 [videoFailureMessage] 翻成一句
///     人话，原始诊断只进失败结果的 `technical`，界面放进折叠的「技术详情」。
///  3. 产物落 `~/Documents/NoNDesign/videos/<job>/frames.mp4`（与艺术架的
///     视频扫描目录同一个根）。移动端不渲染，因此不需要沙盒目录解析。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'app_paths.dart';
import 'video_samples.dart';

// ---------------------------------------------------------------------------
// 平台
// ---------------------------------------------------------------------------

/// 渲染能力只看这一层：桌面三平台可以 spawn 外部程序，移动端不行。
enum VideoHost {
  macos,
  windows,
  linux,
  ios,
  android,
  other;

  /// 当前进程所在的主机。
  static VideoHost current() {
    if (Platform.isMacOS) return VideoHost.macos;
    if (Platform.isWindows) return VideoHost.windows;
    if (Platform.isLinux) return VideoHost.linux;
    if (Platform.isIOS) return VideoHost.ios;
    if (Platform.isAndroid) return VideoHost.android;
    return VideoHost.other;
  }

  /// 能否调外部渲染程序（桌面三平台）。
  bool get isDesktop =>
      this == VideoHost.macos || this == VideoHost.windows || this == VideoHost.linux;
}

// ---------------------------------------------------------------------------
// 拒绝与文案
// ---------------------------------------------------------------------------

/// 管线硬门拒绝（fail-closed）。
///
/// [code] 是稳定代号（测试与日志使用），[detail] 是原始诊断。两者都不直接
/// 上屏——用户看到的是 [videoFailureMessage] 的一句话。
class VideoRejected implements Exception {
  const VideoRejected(this.code, [this.detail = '']);

  final String code;
  final String detail;

  /// 日志/折叠详情用的一行。
  String get technical => detail.isEmpty ? code : '$code: $detail';

  @override
  String toString() => 'VideoRejected($technical)';
}

/// 内部代号 → 用户可见句子。
///
/// 措辞纪律（`docs/copy-glossary.md`）：只回答「发生了什么 + 下一步」，
/// 不出现实现名、错误码、工具名或文件格式名。
String videoFailureMessage(Object? error) {
  // 既接受异常对象，也接受任务快照里保存的代号字符串。
  final code = error is VideoRejected
      ? error.code
      : error is String
          ? error
          : '';
  switch (code) {
    case 'spec_missing':
      return '这份脚本还缺一份说明规范，先补齐规范再渲染';
    case 'spec_invalid':
      return '说明规范不完整，请按模板补齐后再试';
    case 'no_scenes':
      return '脚本里还没有任何场景';
    case 'no_frames':
      return '所有场景的时长都是 0，渲染不出画面';
    case 'undeclared_symbol':
      return '脚本里用了没在规范中声明的量或公式';
    case 'expr_syntax_error':
      return '脚本里有一处算式写错了';
    case 'expr_forbidden_construct':
    case 'expr_forbidden_operator':
      return '算式只支持四则运算、次方与常用数学函数';
    case 'expr_unknown_function':
      return '算式里用到了不支持的函数';
    case 'expr_domain_error':
      return '算式在某一段算不出有效数值（比如除以 0）';
    case 'expr_bad_constant':
      return '算式里出现了不支持的常量';
    case 'image_missing':
      return '脚本引用的图片不在了';
    case 'rasterizer_missing':
      return '这台电脑缺少把画面转成图片的组件，请先安装后重试';
    case 'encoder_missing':
      return '这台电脑缺少视频编码组件，请先安装后重试';
    case 'render_desktop_only':
      return '视频导出只在电脑上可用，手机上可以先编辑脚本、做对照检查，并播放已有的视频';
    case 'render_failed':
      return '视频没有渲染完成，请重试';
    case 'sample_missing':
      return '内置示例没能加载，请重新安装应用';
    case 'job_missing':
      return '这个渲染任务已经不在了';
    case 'timeline_invalid':
      return '脚本格式不对，请检查括号、引号与逗号';
    default:
      return '这次操作没有成功，请重试';
  }
}

// ---------------------------------------------------------------------------
// 规范
// ---------------------------------------------------------------------------

/// 规范的两条线：教育类（science）与艺术类（screenplay）。
enum VideoSpecKind { science, screenplay }

/// 解析并按硬门校验过的规范。
class VideoSpec {
  const VideoSpec({
    required this.kind,
    required this.raw,
    required this.params,
    required this.formulaSources,
  });

  final VideoSpecKind kind;
  final Map<String, dynamic> raw;

  /// 数值参数（量纲写在 note/facts 里，参数本身只许是数字）。
  final Map<String, num> params;

  /// 公式名 → 算式原文（保持声明顺序）。
  final Map<String, String> formulaSources;

  /// 标题：科学类用 subject，艺术类用 title/style。
  String get title {
    final subject = raw['subject'];
    if (subject is String && subject.trim().isNotEmpty) return subject.trim();
    final title = raw['title'];
    if (title is String && title.trim().isNotEmpty) return title.trim();
    final style = raw['style'];
    if (style is String && style.trim().isNotEmpty) return style.trim();
    return kind == VideoSpecKind.science ? '科学说明' : '剧本';
  }
}

/// 校验并规范化规范。
///
/// 与旧管线的五条规则逐条对齐：`spec_missing`（时间线没有 spec 字段 /
/// 规范缺失）、`spec_invalid`（kind 不认识、必填项为空、params 非数值、
/// formulas 条目缺 name/expr）。
VideoSpec parseVideoSpec(Map<String, dynamic> timeline, Map<String, dynamic>? spec) {
  final ref = timeline['spec'];
  if (ref is! String || ref.trim().isEmpty) {
    throw const VideoRejected('spec_missing', '时间线缺少 spec 字段（规范先行）');
  }
  if (spec == null) {
    throw VideoRejected('spec_missing', '找不到规范文件 $ref');
  }
  final kind = spec['kind'];
  if (kind == 'science') {
    for (final field in const ['subject', 'laws', 'assumptions', 'facts']) {
      final value = spec[field];
      final emptyList = value is List && value.isEmpty;
      if (value == null || (value is String && value.trim().isEmpty) || emptyList) {
        throw VideoRejected('spec_invalid', '科学规范缺少非空 $field');
      }
    }
    for (final field in const ['laws', 'assumptions', 'facts']) {
      if (spec[field] is! List) {
        throw VideoRejected('spec_invalid', '$field 必须是数组');
      }
    }
    final params = _paramsOf(spec, required: false);
    final formulas = _formulasOf(spec);
    return VideoSpec(
      kind: VideoSpecKind.science,
      raw: spec,
      params: params,
      formulaSources: formulas,
    );
  }
  if (kind == 'screenplay') {
    final style = spec['style'];
    if (style is! String || style.trim().isEmpty) {
      throw const VideoRejected('spec_invalid', '剧本规范缺少 style');
    }
    final beats = spec['beats'];
    if (beats is! List || beats.isEmpty) {
      throw const VideoRejected('spec_invalid', '剧本规范缺少 beats');
    }
    final params = _paramsOf(spec, required: false);
    final formulas = _formulasOf(spec);
    return VideoSpec(
      kind: VideoSpecKind.screenplay,
      raw: spec,
      params: params,
      formulaSources: formulas,
    );
  }
  throw const VideoRejected('spec_invalid', 'kind 必须是 science | screenplay');
}

Map<String, num> _paramsOf(Map<String, dynamic> spec, {required bool required}) {
  if (required && !spec.containsKey('params')) {
    throw const VideoRejected('spec_invalid', '缺少 params');
  }
  final raw = spec['params'];
  if (raw == null) return const <String, num>{};
  if (raw is! Map) {
    throw const VideoRejected('spec_invalid', 'params 必须是对象');
  }
  final out = <String, num>{};
  for (final entry in raw.entries) {
    final value = entry.value;
    // 布尔在数值语义上是陷阱（true 不是 1），一律拒绝。
    if (value is! num || value is bool) {
      throw VideoRejected('spec_invalid', 'params.${entry.key} 必须是数字（量纲写进说明，不加单位后缀）');
    }
    out['${entry.key}'] = value;
  }
  return out;
}

Map<String, String> _formulasOf(Map<String, dynamic> spec) {
  final raw = spec['formulas'];
  if (raw == null) return const <String, String>{};
  if (raw is! List) {
    throw const VideoRejected('spec_invalid', 'formulas 必须是数组');
  }
  final out = <String, String>{};
  for (final item in raw) {
    if (item is! Map) {
      throw const VideoRejected('spec_invalid', 'formulas 每条需要 name+expr');
    }
    final name = item['name'];
    final expr = item['expr'];
    if (name is! String || name.trim().isEmpty || expr is! String || expr.trim().isEmpty) {
      throw const VideoRejected('spec_invalid', 'formulas 每条需要 name+expr');
    }
    out[name.trim()] = expr.trim();
  }
  return out;
}

// ---------------------------------------------------------------------------
// 算式
// ---------------------------------------------------------------------------

/// 数学函数白名单（与旧管线一字不差）。其余调用一律 `expr_unknown_function`。
const Map<String, int> _functions = <String, int>{
  'sin': 1,
  'cos': 1,
  'tan': 1,
  'asin': 1,
  'acos': 1,
  'atan': 1,
  'atan2': 2,
  'sqrt': 1,
  'abs': 1,
  'min': -1, // 至少 1 个参数
  'max': -1,
  'floor': 1,
  'ceil': 1,
  'log': 1,
  'exp': 1,
  'pow': 2,
  'radians': 1,
  'degrees': 1,
};

/// 内置常量。
const Map<String, double> _constants = <String, double>{
  'pi': math.pi,
  'e': math.e,
};

/// 预编译的算式。
///
/// 编译期：语法、禁用结构（属性访问/下标/lambda/推导式）、未知函数、未声明
/// 符号全部拒绝。求值期：除零/负数开方/log(0)/负底数非整数次方等一律转成
/// `expr_domain_error`，复数与非有限值不许进 SVG 坐标。
class VideoExpr {
  VideoExpr._(this.source, this._root, this.symbols);

  final String source;
  final _ExprNode _root;

  /// 式中出现过的全部标识符（含函数名，与旧实现一致）。
  final Set<String> symbols;

  /// 编译（fail-closed）。
  static VideoExpr compile(String source, Set<String> allowedSymbols) {
    final parsed = _parseExpression(source);
    final undeclared = <String>[
      for (final name in parsed.symbols)
        if (!allowedSymbols.contains(name) && !_functions.containsKey(name)) name,
    ]..sort();
    if (undeclared.isNotEmpty) {
      throw VideoRejected(
        'undeclared_symbol',
        '${undeclared.join(',')} 不在规范声明内（$source）',
      );
    }
    return VideoExpr._(source, parsed.node, parsed.symbols);
  }

  /// 只做结构解析并返回标识符集合（对照检查用：未声明符号由调用方汇总）。
  static Set<String> namesOf(String source) => _parseExpression(source).symbols;

  /// 求值。[env] 的值可以是 num 或时间相关公式的 [VideoExpr]。
  double evaluate(Map<String, Object> env) {
    final value = _root.eval(env, source);
    if (!value.isFinite) {
      throw VideoRejected('expr_domain_error', '$source 产出非有限值 $value');
    }
    return value;
  }
}

class _ParsedExpr {
  const _ParsedExpr(this.node, this.symbols);
  final _ExprNode node;
  final Set<String> symbols;
}

abstract class _ExprNode {
  double eval(Map<String, Object> env, String source);
}

class _NumNode implements _ExprNode {
  const _NumNode(this.value);
  final double value;

  @override
  double eval(Map<String, Object> env, String source) => value;
}

class _VarNode implements _ExprNode {
  const _VarNode(this.name);
  final String name;

  @override
  double eval(Map<String, Object> env, String source) {
    if (env.containsKey(name)) {
      final value = env[name];
      if (value is num) return value.toDouble();
      if (value is VideoExpr) return value.evaluate(env);
      throw VideoRejected('undeclared_symbol', '$name 的值不是数字（$source）');
    }
    final constant = _constants[name];
    if (constant != null) return constant;
    throw VideoRejected('undeclared_symbol', '$name（$source）');
  }
}

class _UnaryNode implements _ExprNode {
  const _UnaryNode(this.negate, this.child);
  final bool negate;
  final _ExprNode child;

  @override
  double eval(Map<String, Object> env, String source) {
    final value = child.eval(env, source);
    return negate ? -value : value;
  }
}

class _BinaryNode implements _ExprNode {
  const _BinaryNode(this.op, this.left, this.right);
  final String op;
  final _ExprNode left;
  final _ExprNode right;

  @override
  double eval(Map<String, Object> env, String source) {
    final l = left.eval(env, source);
    final r = right.eval(env, source);
    switch (op) {
      case '+':
        return l + r;
      case '-':
        return l - r;
      case '*':
        return l * r;
      case '/':
        if (r == 0) throw VideoRejected('expr_domain_error', '除零（$source）');
        return l / r;
      case '//':
        if (r == 0) throw VideoRejected('expr_domain_error', '除零（$source）');
        return (l / r).floorToDouble();
      case '%':
        if (r == 0) throw VideoRejected('expr_domain_error', '模零（$source）');
        return l % r;
      case '**':
        if (l < 0 && r != r.truncateToDouble()) {
          throw VideoRejected('expr_domain_error', '负底数非整数次方（$source）');
        }
        final value = math.pow(l, r).toDouble();
        if (!value.isFinite) {
          throw VideoRejected('expr_domain_error', '$source 产出非有限值');
        }
        return value;
    }
    throw VideoRejected('expr_forbidden_operator', op);
  }
}

class _CallNode implements _ExprNode {
  const _CallNode(this.name, this.args);
  final String name;
  final List<_ExprNode> args;

  @override
  double eval(Map<String, Object> env, String source) {
    final values = [for (final arg in args) arg.eval(env, source)];
    final arity = _functions[name];
    if (arity == null) {
      throw VideoRejected('expr_unknown_function', '$name（$source）');
    }
    if (arity < 0) {
      if (values.isEmpty) {
        throw VideoRejected('expr_domain_error', '$name 需要至少一个参数（$source）');
      }
    } else if (values.length != arity) {
      throw VideoRejected('expr_domain_error', '$name 需要 $arity 个参数（$source）');
    }
    final v = values;
    try {
      switch (name) {
        case 'sin':
          return math.sin(v[0]);
        case 'cos':
          return math.cos(v[0]);
        case 'tan':
          return math.tan(v[0]);
        case 'asin':
          return math.asin(v[0]);
        case 'acos':
          return math.acos(v[0]);
        case 'atan':
          return math.atan(v[0]);
        case 'atan2':
          return math.atan2(v[0], v[1]);
        case 'sqrt':
          return math.sqrt(v[0]);
        case 'abs':
          return v[0].abs();
        case 'min':
          return v.reduce(math.min);
        case 'max':
          return v.reduce(math.max);
        case 'floor':
          return v[0].floorToDouble();
        case 'ceil':
          return v[0].ceilToDouble();
        case 'log':
          return math.log(v[0]);
        case 'exp':
          return math.exp(v[0]);
        case 'pow':
          return math.pow(v[0], v[1]).toDouble();
        case 'radians':
          return v[0] * math.pi / 180.0;
        case 'degrees':
          return v[0] * 180.0 / math.pi;
      }
    } catch (error) {
      throw VideoRejected('expr_domain_error', '$name(${v.join(',')}) 算不出有效数值');
    }
    throw VideoRejected('expr_unknown_function', name);
  }
}

/// 递归下降解析器。语法即白名单：只认数字、标识符、四则运算、`//`、`%`、
/// `**`、括号、逗号与单/双元正负号；其余结构在解析期就按禁用处理。
class _Parser {
  _Parser(this.source);

  final String source;
  int _index = 0;
  final Set<String> symbols = <String>{};

  _ParsedExpr parse() {
    final node = _parseAdditive();
    _skipSpace();
    if (_index < source.length) {
      final rest = source.substring(_index);
      final head = rest[0];
      if ('[]{}.,<>!=&|^~:;'.contains(head)) {
        throw VideoRejected('expr_forbidden_construct', '$source 只允许算术/函数调用');
      }
      throw VideoRejected('expr_syntax_error', '$source 无法解析：$rest');
    }
    return _ParsedExpr(node, symbols);
  }

  void _skipSpace() {
    while (_index < source.length && source[_index].trim().isEmpty) {
      _index++;
    }
  }

  bool _match(String token) {
    if (source.startsWith(token, _index)) {
      _index += token.length;
      return true;
    }
    return false;
  }

  _ExprNode _parseAdditive() {
    var left = _parseMultiplicative();
    while (true) {
      _skipSpace();
      if (_match('+')) {
        left = _BinaryNode('+', left, _parseMultiplicative());
      } else if (_match('-')) {
        left = _BinaryNode('-', left, _parseMultiplicative());
      } else {
        return left;
      }
    }
  }

  _ExprNode _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      _skipSpace();
      if (source.startsWith('//', _index)) {
        _index += 2;
        left = _BinaryNode('//', left, _parseUnary());
      } else if (_match('*')) {
        left = _BinaryNode('*', left, _parseUnary());
      } else if (_match('/')) {
        left = _BinaryNode('/', left, _parseUnary());
      } else if (_match('%')) {
        left = _BinaryNode('%', left, _parseUnary());
      } else {
        return left;
      }
    }
  }

  _ExprNode _parseUnary() {
    _skipSpace();
    if (_match('-')) return _UnaryNode(true, _parseUnary());
    if (_match('+')) return _UnaryNode(false, _parseUnary());
    return _parsePower();
  }

  _ExprNode _parsePower() {
    final base = _parsePrimary();
    _skipSpace();
    // 右结合：2 ** 3 ** 2 == 2 ** (3 ** 2)。
    if (source.startsWith('**', _index)) {
      _index += 2;
      return _BinaryNode('**', base, _parseUnary());
    }
    return base;
  }

  _ExprNode _parsePrimary() {
    _skipSpace();
    if (_index >= source.length) {
      throw VideoRejected('expr_syntax_error', '$source 提前结束');
    }
    final ch = source[_index];
    if (ch == '(') {
      _index++;
      final inner = _parseAdditive();
      _skipSpace();
      if (!_match(')')) {
        throw VideoRejected('expr_syntax_error', '$source 缺少右括号');
      }
      return inner;
    }
    if (_isDigit(ch) || (ch == '.' && _index + 1 < source.length && _isDigit(source[_index + 1]))) {
      return _parseNumber();
    }
    if (_isIdentStart(ch)) {
      final name = _parseIdentifier();
      _skipSpace();
      if (_match('(')) {
        final args = <_ExprNode>[];
        _skipSpace();
        if (!_match(')')) {
          while (true) {
            args.add(_parseAdditive());
            _skipSpace();
            if (_match(',')) continue;
            if (_match(')')) break;
            throw VideoRejected('expr_syntax_error', '$source 函数参数无法解析');
          }
        }
        if (!_functions.containsKey(name)) {
          throw VideoRejected('expr_unknown_function', '$name 不在白名单');
        }
        symbols.add(name);
        return _CallNode(name, args);
      }
      symbols.add(name);
      return _VarNode(name);
    }
    if ('[]{}.,<>!=&|^~:;'.contains(ch)) {
      throw VideoRejected('expr_forbidden_construct', '$source 只允许算术/函数调用');
    }
    throw VideoRejected('expr_syntax_error', '$source 无法解析 $ch');
  }

  _ExprNode _parseNumber() {
    final start = _index;
    while (_index < source.length && _isDigit(source[_index])) {
      _index++;
    }
    if (_index < source.length && source[_index] == '.') {
      _index++;
      while (_index < source.length && _isDigit(source[_index])) {
        _index++;
      }
    }
    if (_index < source.length && (source[_index] == 'e' || source[_index] == 'E')) {
      final mark = _index;
      _index++;
      if (_index < source.length && (source[_index] == '+' || source[_index] == '-')) {
        _index++;
      }
      if (_index >= source.length || !_isDigit(source[_index])) {
        _index = mark; // 回退：'2e' 视为 2 后面跟了非法标识符
      } else {
        while (_index < source.length && _isDigit(source[_index])) {
          _index++;
        }
      }
    }
    final text = source.substring(start, _index);
    final value = double.tryParse(text);
    if (value == null) {
      throw VideoRejected('expr_syntax_error', '$source 数字无法解析：$text');
    }
    if (_index < source.length && _isIdentStart(source[_index])) {
      throw VideoRejected('expr_syntax_error', '$source 数字后紧跟标识符');
    }
    return _NumNode(value);
  }

  String _parseIdentifier() {
    final start = _index;
    while (_index < source.length && _isIdentPart(source[_index])) {
      _index++;
    }
    return source.substring(start, _index);
  }

  static bool _isDigit(String ch) => ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;

  static bool _isIdentStart(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
  }

  static bool _isIdentPart(String ch) => _isIdentStart(ch) || _isDigit(ch);
}

_ParsedExpr _parseExpression(String source) {
  if (source.trim().isEmpty) {
    throw const VideoRejected('expr_syntax_error', '算式为空');
  }
  return _Parser(source).parse();
}

// ---------------------------------------------------------------------------
// 脚本（时间线）
// ---------------------------------------------------------------------------

/// 解析、校验并预编译过的视频脚本。
class VideoDocument {
  VideoDocument._({
    required this.timeline,
    required this.spec,
    required this.baseDir,
    required this.allowedSymbols,
    required this.env,
    required this.width,
    required this.height,
    required this.fps,
    required this.totalSeconds,
  });

  final Map<String, dynamic> timeline;
  final VideoSpec spec;

  /// 图片相对路径的解析基准（无图片时可为空）。
  final Directory? baseDir;

  /// 硬门 2 的允许符号集合（`t/T` + 参数 + 公式 + `pi/e`）。
  final Set<String> allowedSymbols;

  /// 静态环境：参数与常量公式已求值；时间相关公式保留为 [VideoExpr]。
  final Map<String, Object> env;

  final int width;
  final int height;
  final int fps;
  final double totalSeconds;

  /// 算式编译缓存：同一算式在一帧里可能出现多次（几百帧 × 多个元素），
  /// 编译一次即可（与旧管线的 `_EXPR_CACHE` 同义）。
  final Map<String, VideoExpr> _exprCache = <String, VideoExpr>{};

  VideoExpr _exprFor(String source) {
    final cached = _exprCache[source];
    if (cached != null) return cached;
    final compiled = VideoExpr.compile(source, allowedSymbols);
    _exprCache[source] = compiled;
    return compiled;
  }

  /// 按 [fps] 计算的帧数（截断，与旧管线一致）。
  int frameCount([int? atFps]) {
    final rate = atFps ?? fps;
    return (totalSeconds * rate).floor();
  }

  /// 从两份已解析的映射构建。
  ///
  /// 硬门 1 在这里是严格的：时间线必须携带非空的 `spec` 字段，规范映射必须
  /// 提供（编辑器路径由 [fromScripts] 负责补字段，见其注释）。
  factory VideoDocument.build({
    required Map<String, dynamic> timeline,
    required Map<String, dynamic>? spec,
    Directory? baseDir,
  }) {
    final tl = Map<String, dynamic>.from(timeline);
    final parsedSpec = parseVideoSpec(tl, spec);

    final allowed = <String>{
      't',
      'T',
      ...parsedSpec.params.keys,
      ...parsedSpec.formulaSources.keys,
      ..._constants.keys,
    };

    // 规范里的公式先过同一套白名单（规范层的想当然也进不来）。
    final formulaExprs = <String, VideoExpr>{};
    for (final entry in parsedSpec.formulaSources.entries) {
      formulaExprs[entry.key] = VideoExpr.compile(entry.value, allowed);
    }

    final scenes = tl['scenes'];
    if (scenes is! List || scenes.isEmpty) {
      throw const VideoRejected('no_scenes', 'timeline.scenes 为空');
    }

    // 帧前全量预编译：语法/符号错误在第一帧之前报干净。
    for (final source in collectVideoExprSources(scenes)) {
      VideoExpr.compile(source, allowed);
    }

    final width = _intOf(tl['width'], 1280);
    final height = _intOf(tl['height'], 720);
    final fps = _intOf(tl['fps'], 30);
    final totalSeconds = _totalSecondsOf(tl);
    if (totalSeconds <= 0) {
      throw const VideoRejected('no_frames', 'scenes 时长全为 0');
    }
    if (fps <= 0 || (totalSeconds * fps).floor() <= 0) {
      throw const VideoRejected('no_frames', 'scenes 时长不足一帧');
    }

    // 公式入 env：纯参数公式按声明顺序求值一次；含 t/T 的保留表达式。
    final env = <String, Object>{...parsedSpec.params};
    for (final entry in formulaExprs.entries) {
      final expr = entry.value;
      if (expr.symbols.contains('t') || expr.symbols.contains('T')) {
        env[entry.key] = expr;
      } else {
        env[entry.key] = expr.evaluate({...env, 't': 0.0, 'T': 0.0});
      }
    }

    return VideoDocument._(
      timeline: tl,
      spec: parsedSpec,
      baseDir: baseDir,
      allowedSymbols: allowed,
      env: env,
      width: width,
      height: height,
      fps: fps,
      totalSeconds: totalSeconds,
    );
  }

  /// 从时间线文件构建，规范按 `spec` 字段相对该文件解析（硬门 1 的完整形态）。
  factory VideoDocument.fromFile(File timelineFile) {
    final Map<String, dynamic> tl;
    try {
      final decoded = jsonDecode(timelineFile.readAsStringSync());
      if (decoded is! Map) throw const FormatException('根节点不是对象');
      tl = Map<String, dynamic>.from(decoded);
    } catch (error) {
      throw VideoRejected('timeline_invalid', '$error');
    }
    final ref = tl['spec'];
    if (ref is! String || ref.trim().isEmpty) {
      throw const VideoRejected('spec_missing', '时间线缺少 spec 字段');
    }
    final specFile = File('${timelineFile.parent.path}/$ref');
    if (!specFile.existsSync()) {
      throw VideoRejected('spec_missing', '${specFile.path} 不存在');
    }
    final Map<String, dynamic>? spec;
    try {
      final decoded = jsonDecode(specFile.readAsStringSync());
      spec = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (error) {
      throw VideoRejected('spec_invalid', 'JSON 解析失败 $error');
    }
    return VideoDocument.build(
      timeline: tl,
      spec: spec,
      baseDir: timelineFile.parent,
    );
  }

  /// 从脚本编辑器的两段文本构建。
  ///
  /// 编辑器里规范原文是单独提供的，因此时间线缺少 `spec` 字段时补一个占位名
  /// （规范的**内容**仍要过 [parseVideoSpec] 的完整硬门）。
  factory VideoDocument.fromScripts({
    required String timelineJson,
    required String specJson,
  }) {
    if (specJson.trim().isEmpty) {
      throw const VideoRejected('spec_missing', 'spec 文本为空');
    }
    final Map<String, dynamic> tl;
    final Map<String, dynamic>? spec;
    try {
      final decoded = jsonDecode(timelineJson);
      if (decoded is! Map) throw const FormatException('根节点不是对象');
      tl = Map<String, dynamic>.from(decoded);
    } catch (error) {
      throw VideoRejected('timeline_invalid', '$error');
    }
    try {
      final decoded = jsonDecode(specJson);
      spec = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      if (spec == null) throw const FormatException('根节点不是对象');
    } catch (error) {
      throw VideoRejected('spec_invalid', 'JSON 解析失败 $error');
    }
    final ref = tl['spec'];
    if (ref is! String || ref.trim().isEmpty) {
      tl['spec'] = 'spec.json';
    }
    return VideoDocument.build(timeline: tl, spec: spec);
  }

  /// 生成第 [tGlobal] 秒的整帧 SVG（确定性：同文档同时间必同字节）。
  String frameSvg(double tGlobal) {
    final parts = <String>[
      '<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" '
          'viewBox="0 0 $width $height">',
    ];
    final background = _stringOf(timeline['background'], '#0B0D12');
    parts.add('<rect width="$width" height="$height" fill="$background"/>');
    var remain = tGlobal;
    for (final scene in _scenes(timeline)) {
      final duration = _doubleOf(scene['duration'], 0.0);
      // 浮点容差：t 恰好等于场景结束时刻仍渲染该场景终态（防边界闪黑）。
      if (remain > duration + 1e-9) {
        remain -= duration;
        continue;
      }
      final sceneBackground = _stringOf(scene['background'], background);
      parts.add('<rect width="$width" height="$height" fill="$sceneBackground"/>');
      final env = <String, Object>{...this.env, 't': remain, 'T': tGlobal};
      for (final element in _elements(scene)) {
        parts.add(_elementSvg(element, remain, tGlobal, env));
      }
      break;
    }
    parts.add('</svg>');
    return parts.join();
  }

  // ---- 值解析 ----

  double _resolve(Object? value, Map<String, Object> env, String axis) {
    if (value is VideoExpr) return value.evaluate(env);
    if (value is Map) {
      final expr = value['expr'];
      if (expr is String) return _exprFor(expr).evaluate(env);
      return 0.0;
    }
    if (value is String) {
      final text = value.trim();
      if (text.endsWith('%')) {
        final total = axis == 'x' ? width.toDouble() : height.toDouble();
        final pct = double.tryParse(text.substring(0, text.length - 1)) ?? 0;
        return total * pct / 100.0;
      }
      if (text == 'center' || text == 'middle') {
        return (axis == 'x' ? width : height) / 2.0;
      }
      return double.tryParse(text) ?? 0.0;
    }
    if (value is num) return value.toDouble();
    return 0.0;
  }

  // ---- 元素 ----

  String _elementSvg(
    Map<String, dynamic> element,
    double tScene,
    double tGlobal,
    Map<String, Object> env,
  ) {
    final anim = _animFactor(element['anim'], tScene);
    final motion = _motionOffset(element['motion'], tScene, env);
    if (anim.alpha <= 0.01) return '';
    final kind = _stringOf(element['type'], '');
    final color = _stringOf(element['color'], '#FFFFFF');
    final opacity = _doubleOf(element['opacity'], 1.0) * anim.alpha;
    final attributes = <String>['opacity="${opacity.toStringAsFixed(3)}"'];

    double position(Object? value, String axis) =>
        motion.absolute ? 0.0 : _resolve(value, env, axis);
    double size(Object? value, String axis) => _resolve(value, env, axis);

    switch (kind) {
      case 'text':
        final x = position(element['x'] ?? '50%', 'x') + motion.dx;
        final y = position(element['y'] ?? '50%', 'y') + anim.dy + motion.dy;
        final fontSize = _doubleOf(element['size'], 32.0) * anim.scale;
        final anchor = _stringOf(element['anchor'], 'middle');
        final weight = _stringOf(element['weight'], '600');
        final family = _stringOf(element['font'], 'PingFang SC');
        final String content;
        final textValue = element['textValue'];
        if (textValue is Map) {
          final exprSource = textValue['expr'];
          if (exprSource is! String || exprSource.trim().isEmpty) {
            throw const VideoRejected('spec_invalid', 'textValue 需要 expr');
          }
          final value = _exprFor(exprSource).evaluate(env);
          content = _escape(_formatValue(value, textValue['format']));
        } else {
          content = _escape(_stringOf(element['text'], ''));
        }
        attributes.add('font-family="$family" font-size="${fontSize.toStringAsFixed(1)}" '
            'fill="$color" text-anchor="$anchor" font-weight="$weight"');
        return '<text x="${x.toStringAsFixed(1)}" y="${y.toStringAsFixed(1)}" '
            '${attributes.join(' ')}>$content</text>';
      case 'rect':
        final x = position(element['x'] ?? 0, 'x') + motion.dx;
        final y = position(element['y'] ?? 0, 'y') + motion.dy;
        final w = size(element['w'] ?? 100, 'x') * anim.scale;
        final h = size(element['h'] ?? 60, 'y') * anim.scale;
        final cx = x + w / 2;
        final cy = y + h / 2;
        final radius = _doubleOf(element['radius'], 8.0);
        final body = '<rect x="${(cx - w / 2).toStringAsFixed(1)}" '
            'y="${(cy + anim.dy - h / 2).toStringAsFixed(1)}" '
            'width="${w.toStringAsFixed(1)}" height="${h.toStringAsFixed(1)}" '
            'rx="${radius.toStringAsFixed(1)}" fill="$color"/>';
        return '<g ${attributes.join(' ')}>$body</g>';
      case 'circle':
        final cx = position(element['cx'] ?? '50%', 'x') + motion.dx;
        final cy = position(element['cy'] ?? '50%', 'y') + anim.dy + motion.dy;
        final r = size(element['r'] ?? 40, 'x') * anim.scale;
        return '<g ${attributes.join(' ')}><circle cx="${cx.toStringAsFixed(1)}" '
            'cy="${cy.toStringAsFixed(1)}" r="${r.toStringAsFixed(1)}" fill="$color"/></g>';
      case 'ellipse':
        final cx = position(element['cx'] ?? '50%', 'x') + motion.dx;
        final cy = position(element['cy'] ?? '50%', 'y') + anim.dy + motion.dy;
        final rx = size(element['rx'] ?? 50, 'x') * anim.scale;
        final ry = size(element['ry'] ?? 30, 'y') * anim.scale;
        return '<g ${attributes.join(' ')}><ellipse cx="${cx.toStringAsFixed(1)}" '
            'cy="${cy.toStringAsFixed(1)}" rx="${rx.toStringAsFixed(1)}" '
            'ry="${ry.toStringAsFixed(1)}" fill="$color"/></g>';
      case 'line':
        final x1 = position(element['x1'] ?? 0, 'x') + motion.dx;
        final y1 = position(element['y1'] ?? 0, 'y') + anim.dy + motion.dy;
        final x2 = position(element['x2'] ?? 100, 'x') + motion.dx;
        final y2 = position(element['y2'] ?? 0, 'y') + anim.dy + motion.dy;
        final strokeWidth = _doubleOf(element['stroke_width'], 2.0) * anim.scale;
        return '<g ${attributes.join(' ')}><line x1="${x1.toStringAsFixed(1)}" '
            'y1="${y1.toStringAsFixed(1)}" x2="${x2.toStringAsFixed(1)}" '
            'y2="${y2.toStringAsFixed(1)}" stroke="$color" '
            'stroke-width="${strokeWidth.toStringAsFixed(1)}" stroke-linecap="round"/></g>';
      case 'arrow':
        final x1 = position(element['x1'] ?? 0, 'x') + motion.dx;
        final y1 = position(element['y1'] ?? 0, 'y') + anim.dy + motion.dy;
        final x2 = position(element['x2'] ?? 100, 'x') + motion.dx;
        final y2 = position(element['y2'] ?? 0, 'y') + anim.dy + motion.dy;
        final strokeWidth = _doubleOf(element['stroke_width'], 3.0) * anim.scale;
        final head = _doubleOf(element['head'], 14.0) * anim.scale;
        final angle = math.atan2(y2 - y1, x2 - x1);
        final bx = x2 - head * math.cos(angle);
        final by = y2 - head * math.sin(angle);
        final perpendicular = angle + math.pi / 2;
        final p1x = bx + head * 0.42 * math.cos(perpendicular);
        final p1y = by + head * 0.42 * math.sin(perpendicular);
        final p2x = bx - head * 0.42 * math.cos(perpendicular);
        final p2y = by - head * 0.42 * math.sin(perpendicular);
        final body = '<line x1="${x1.toStringAsFixed(1)}" y1="${y1.toStringAsFixed(1)}" '
            'x2="${bx.toStringAsFixed(1)}" y2="${by.toStringAsFixed(1)}" stroke="$color" '
            'stroke-width="${strokeWidth.toStringAsFixed(1)}" stroke-linecap="round"/>'
            '<polygon points="${x2.toStringAsFixed(1)},${y2.toStringAsFixed(1)} '
            '${p1x.toStringAsFixed(1)},${p1y.toStringAsFixed(1)} '
            '${p2x.toStringAsFixed(1)},${p2y.toStringAsFixed(1)}" fill="$color"/>';
        return '<g ${attributes.join(' ')}>$body</g>';
      case 'polyline':
        final points = element['points'];
        if (points is! List || points.length < 2) return '';
        final coords = <String>[];
        for (final point in points) {
          if (point is! List || point.length < 2) continue;
          final x = position(point[0], 'x') + motion.dx;
          final y = position(point[1], 'y') + anim.dy + motion.dy;
          coords.add('${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}');
        }
        final strokeWidth = _doubleOf(element['stroke_width'], 2.0) * anim.scale;
        final fill = _stringOf(element['fill'], 'none');
        return '<g ${attributes.join(' ')}><polyline points="${coords.join(' ')}" '
            'fill="$fill" stroke="$color" stroke-width="${strokeWidth.toStringAsFixed(1)}" '
            'stroke-linecap="round" stroke-linejoin="round"/></g>';
      case 'image':
        final x = position(element['x'] ?? 0, 'x') + motion.dx;
        final y = position(element['y'] ?? 0, 'y') + anim.dy + motion.dy;
        final w = size(element['w'] ?? 200, 'x') * anim.scale;
        final h = size(element['h'] ?? 200, 'y') * anim.scale;
        final path = _stringOf(element['path'], '');
        if (path.isEmpty) return '';
        final file = File(path).isAbsolute ? File(path) : File('${baseDir?.path ?? '.'}/$path');
        if (!file.existsSync()) {
          throw VideoRejected('image_missing', '$path（解析为 ${file.path}）');
        }
        final suffix = file.path.toLowerCase();
        final mime = suffix.endsWith('.jpg') || suffix.endsWith('.jpeg')
            ? 'image/jpeg'
            : suffix.endsWith('.webp')
                ? 'image/webp'
                : 'image/png';
        final b64 = base64Encode(file.readAsBytesSync());
        return '<g ${attributes.join(' ')}><image x="${x.toStringAsFixed(1)}" '
            'y="${y.toStringAsFixed(1)}" width="${w.toStringAsFixed(1)}" '
            'height="${h.toStringAsFixed(1)}" href="data:$mime;base64,$b64" '
            'preserveAspectRatio="xMidYMid slice"/></g>';
    }
    return '';
  }

  _AnimFactor _animFactor(Object? raw, double tScene) {
    if (raw is! Map) return const _AnimFactor(1, 0, 1);
    final duration = _doubleOf(raw['dur'], 0.5);
    final delay = _doubleOf(raw['delay'], 0.0);
    final local = tScene - delay;
    if (local < 0) return const _AnimFactor(0, 0, 1);
    final progress = duration > 0 ? math.min(1.0, local / duration) : 1.0;
    final ease = 1 - math.pow(1 - progress, 3).toDouble();
    final kind = _stringOf(raw['in'], 'fade');
    if (kind == 'rise') return _AnimFactor(ease, (1 - ease) * 40, 1);
    if (kind == 'pop') {
      final scale = 0.6 + 0.4 * ease + (ease < 1 ? 0.08 * math.sin(ease * math.pi) : 0.0);
      return _AnimFactor(ease, 0, scale);
    }
    return _AnimFactor(ease, 0, 1); // fade / 未知 → 按 fade
  }

  /// 持续运动 → (dx, dy, 是否绝对位置)。
  ///
  /// linear 是加性偏移；orbit / path 完全决定元素位置（元素自身坐标返回 0）。
  _MotionOffset _motionOffset(Object? raw, double tScene, Map<String, Object> env) {
    if (raw is! Map) return const _MotionOffset(0, 0, false);
    final kind = _stringOf(raw['type'], 'linear');
    if (kind == 'linear') {
      final vx = _resolveExpr(raw['vx'] ?? 0, env);
      final vy = _resolveExpr(raw['vy'] ?? 0, env);
      return _MotionOffset(vx * tScene, vy * tScene, false);
    }
    if (kind == 'orbit') {
      final cx = _resolveExpr(raw['cx'] ?? 0, env);
      final cy = _resolveExpr(raw['cy'] ?? 0, env);
      final r = _resolveExpr(raw['r'] ?? 50, env);
      final omega = _resolveExpr(raw['omega'] ?? 1, env);
      final angle = omega * tScene;
      return _MotionOffset(cx + r * math.cos(angle), cy + r * math.sin(angle), true);
    }
    if (kind == 'path') {
      final points = raw['points'];
      if (points is! List || points.length < 2) {
        return const _MotionOffset(0, 0, false);
      }
      final speed = _resolveExpr(raw['speed'] ?? 100, env);
      final distance = speed * tScene;
      var accumulated = 0.0;
      for (var i = 0; i < points.length - 1; i++) {
        final first = points[i];
        final second = points[i + 1];
        if (first is! List || second is! List || first.length < 2 || second.length < 2) {
          continue;
        }
        final x1 = _doubleOf(first[0], 0);
        final y1 = _doubleOf(first[1], 0);
        final x2 = _doubleOf(second[0], 0);
        final y2 = _doubleOf(second[1], 0);
        final segment = math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));
        if (accumulated + segment >= distance) {
          final fraction = segment > 0 ? (distance - accumulated) / segment : 0.0;
          return _MotionOffset(x1 + (x2 - x1) * fraction, y1 + (y2 - y1) * fraction, true);
        }
        accumulated += segment;
      }
      final last = points.last;
      return _MotionOffset(
        last is List && last.isNotEmpty ? _doubleOf(last[0], 0) : 0,
        last is List && last.length > 1 ? _doubleOf(last[1], 0) : 0,
        true,
      );
    }
    return const _MotionOffset(0, 0, false);
  }

  double _resolveExpr(Object? value, Map<String, Object> env) {
    if (value is Map && value['expr'] is String) {
      return _exprFor(value['expr'] as String).evaluate(env);
    }
    return _resolve(value, env, 'x');
  }
}

class _AnimFactor {
  const _AnimFactor(this.alpha, this.dy, this.scale);
  final double alpha;
  final double dy;
  final double scale;
}

class _MotionOffset {
  const _MotionOffset(this.dx, this.dy, this.absolute);
  final double dx;
  final double dy;
  final bool absolute;
}

// ---------------------------------------------------------------------------
// 机械对照（环②）
// ---------------------------------------------------------------------------

/// 对照检查结果。
class VideoReviewResult {
  const VideoReviewResult({
    required this.ok,
    required this.totalSeconds,
    required this.problems,
    required this.notes,
    required this.technical,
    this.spec,
    this.sampleTimes = const <double>[],
  });

  final bool ok;
  final double totalSeconds;

  /// 用户可见的问题句（每条一句人话）。
  final List<String> problems;

  /// 允许但值得对照的提示。
  final List<String> notes;

  /// 原始诊断（表达式原文、错误代号），只进折叠的「技术详情」。
  final List<String> technical;

  final VideoSpec? spec;

  /// 抽帧时间点（环③材料；移动端只展示清单，不做视觉评分）。
  final List<double> sampleTimes;

  /// 一句话结论。
  String get summary => ok
      ? '对照检查通过 · 片长 ${totalSeconds.toStringAsFixed(1)} 秒'
      : '对照检查发现 ${problems.length} 处需要修正';

  /// 面板全文（结论 + 问题 + 提示）。
  String get output => <String>[
        summary,
        for (final problem in problems) '· $problem',
        for (final note in notes) '· $note',
      ].join('\n');
}

/// 机械对照：规范复检 + 公式/时间线算式符号闭包 + 节拍覆盖 + 故事板幕数。
///
/// 与旧管线逐条对齐：规范门不通过直接判失败（spec_missing/spec_invalid），
/// 时间线算式聚合未声明符号，剧本节拍必须在片长内，教育类故事板幕数只作提示。
VideoReviewResult reviewVideoScript({
  required Map<String, dynamic> timeline,
  required Map<String, dynamic>? spec,
  int samples = 6,
}) {
  final problems = <String>[];
  final notes = <String>[];
  final technical = <String>[];
  final total = _totalSecondsOf(timeline);

  VideoSpec? parsed;
  try {
    parsed = parseVideoSpec(timeline, spec);
  } on VideoRejected catch (error) {
    problems.add(videoFailureMessage(error));
    technical.add(error.technical);
    return VideoReviewResult(
      ok: false,
      totalSeconds: total,
      problems: problems,
      notes: notes,
      technical: technical,
    );
  }

  final allowed = <String>{
    't',
    'T',
    ...parsed.params.keys,
    ...parsed.formulaSources.keys,
    ..._constants.keys,
  };

  // 公式本身也过一遍结构门（规范层的错误同样不能进渲染）。
  for (final entry in parsed.formulaSources.entries) {
    try {
      VideoExpr.namesOf(entry.value);
    } on VideoRejected catch (error) {
      problems.add('规范里的公式「${entry.key}」写错了');
      technical.add(error.technical);
    }
  }

  final scenes = timeline['scenes'];
  final sources = scenes == null ? const <String>[] : collectVideoExprSources(scenes);
  final undeclared = <String>{};
  for (final source in sources) {
    final Set<String> names;
    try {
      names = VideoExpr.namesOf(source);
    } on VideoRejected catch (error) {
      problems.add(_exprProblem(error));
      technical.add(error.technical);
      continue;
    }
    for (final name in names) {
      if (!allowed.contains(name) && !_functions.containsKey(name)) {
        undeclared.add(name);
      }
    }
  }
  if (undeclared.isNotEmpty) {
    final sorted = undeclared.toList()..sort();
    problems.add('算式里用了没在规范中声明的量：${sorted.join('、')}');
    technical.add('undeclared_symbol: ${sorted.join(',')}');
  }

  if (parsed.kind == VideoSpecKind.screenplay) {
    final beats = spec!['beats'];
    if (beats is List) {
      for (var i = 0; i < beats.length; i++) {
        final beat = beats[i];
        final at = beat is Map ? _doubleOf(beat['at'], -1) : -1.0;
        if (at < 0 || at > total) {
          problems.add('第 ${i + 1} 个节拍落在片长之外（${at.toStringAsFixed(1)} 秒）');
        }
      }
    }
  }

  if (parsed.kind == VideoSpecKind.science) {
    final storyboard = spec!['storyboard'];
    if (storyboard is List && storyboard.isNotEmpty) {
      final scenesCount = scenes is List ? scenes.length : 0;
      if (storyboard.length != scenesCount) {
        notes.add('规范里写了 ${storyboard.length} 幕，脚本里有 $scenesCount 个场景'
            '（允许合并或拆分，对照时留意一下）');
      }
    }
  }

  if (scenes is! List || scenes.isEmpty) {
    problems.add('脚本里还没有任何场景');
    technical.add('no_scenes');
  } else if (total <= 0) {
    problems.add('所有场景的时长都是 0');
    technical.add('no_frames');
  }

  return VideoReviewResult(
    ok: problems.isEmpty,
    totalSeconds: total,
    problems: problems,
    notes: notes,
    technical: technical,
    spec: parsed,
    sampleTimes: videoSampleTimes(total, samples: samples),
  );
}

String _exprProblem(VideoRejected error) {
  switch (error.code) {
    case 'expr_syntax_error':
      return '脚本里有一处算式写错了';
    case 'expr_unknown_function':
      return '算式里用到了不支持的函数';
    case 'expr_forbidden_construct':
    case 'expr_forbidden_operator':
      return '算式只支持四则运算、次方与常用数学函数';
    case 'expr_bad_constant':
      return '算式里出现了不支持的常量';
    default:
      return videoFailureMessage(error);
  }
}

/// 在片长内均匀取 [samples] 个时间点（环③材料）。
List<double> videoSampleTimes(double totalSeconds, {int samples = 6}) {
  if (samples <= 0 || totalSeconds <= 0) return const <double>[];
  return <double>[
    for (var i = 0; i < samples; i++)
      double.parse((totalSeconds * i / samples).toStringAsFixed(3)),
  ];
}

/// 抽帧时间点对应的帧文件路径（帧目录存在时才有意义）。
List<String> videoFrameListing({
  required String framesDirectory,
  required double totalSeconds,
  required int fps,
  int samples = 6,
}) {
  final last = math.max(0, (totalSeconds * fps).floor() - 1);
  return <String>[
    for (final time in videoSampleTimes(totalSeconds, samples: samples))
      '$framesDirectory/frame_${math.min((time * fps).floor(), last).toString().padLeft(5, '0')}.png',
  ];
}

/// 评审 agent 的对照提示词（环③，桌面保留；移动端没有抽帧+视觉链路）。
String videoVisionPrompt(VideoSpec spec) {
  final lines = <String>[
    '你是视频质量评审。对照规范逐条核查抽帧，每条给 PASS/FAIL 与一句证据。',
    '规范主题：${spec.title}',
  ];
  if (spec.kind == VideoSpecKind.science) {
    final assumptions = spec.raw['assumptions'];
    final facts = spec.raw['facts'];
    lines
      ..add('理想化假设：${assumptions is List ? assumptions.join('; ') : ''}')
      ..add('事实核查清单（逐条判真伪）：');
    if (facts is List) {
      for (var i = 0; i < facts.length; i++) {
        lines.add('  ${i + 1}. ${facts[i]}');
      }
    }
  } else {
    final palette = spec.raw['palette'];
    final beats = spec.raw['beats'];
    lines
      ..add('风格锚：${spec.raw['style']}')
      ..add('调色板：$palette')
      ..add('节拍表：');
    if (beats is List) {
      for (final beat in beats) {
        if (beat is Map) lines.add('  ${beat['at']}s ${beat['what']}');
      }
    }
  }
  return lines.join('\n');
}

/// 深扫脚本里全部 `{'expr': ...}`（含 motion/anim/points/textValue）。
List<String> collectVideoExprSources(Object? node) {
  final out = <String>[];
  void walk(Object? value) {
    if (value is Map) {
      final expr = value['expr'];
      if (expr is String) out.add(expr);
      for (final child in value.values) {
        walk(child);
      }
    } else if (value is List) {
      for (final child in value) {
        walk(child);
      }
    }
  }

  walk(node);
  return out;
}

// ---------------------------------------------------------------------------
// 渲染任务
// ---------------------------------------------------------------------------

/// 光栅化器的两种命令行形态。
enum VideoRasterizerKind { resvg, rsvgConvert }

/// 解析到的外部程序。
class VideoBinaries {
  const VideoBinaries({this.rasterizer, this.rasterizerKind, this.encoder});

  final String? rasterizer;
  final VideoRasterizerKind? rasterizerKind;
  final String? encoder;

  bool get canRender => rasterizer != null && encoder != null;
}

/// 任务状态。
enum VideoJobStatus { running, done, failed, cancelled }

/// 渲染任务快照（每次进度变化产生新快照，界面轮询读取）。
class VideoRenderJob {
  const VideoRenderJob({
    required this.id,
    required this.status,
    required this.fps,
    required this.frames,
    required this.totalFrames,
    required this.totalSeconds,
    this.directory,
    this.mp4Path,
    this.failureCode,
    this.log = '',
  });

  final String id;
  final VideoJobStatus status;
  final int fps;
  final int frames;
  final int totalFrames;
  final double totalSeconds;
  final String? directory;
  final String? mp4Path;

  /// 失败时的内部代号（界面经 [videoFailureMessage] 翻译）。
  final String? failureCode;

  /// 诊断日志（只进折叠的「技术详情」）。
  final String log;

  bool get isRunning => status == VideoJobStatus.running;
  bool get isDone => status == VideoJobStatus.done;
  bool get isFailed => status == VideoJobStatus.failed;

  VideoRenderJob copyWith({
    VideoJobStatus? status,
    int? frames,
    String? directory,
    String? mp4Path,
    String? failureCode,
    String? log,
  }) {
    return VideoRenderJob(
      id: id,
      status: status ?? this.status,
      fps: fps,
      frames: frames ?? this.frames,
      totalFrames: totalFrames,
      totalSeconds: totalSeconds,
      directory: directory ?? this.directory,
      mp4Path: mp4Path ?? this.mp4Path,
      failureCode: failureCode ?? this.failureCode,
      log: log ?? this.log,
    );
  }
}

/// 外部进程调用（测试注入假实现，不真 spawn）。
typedef VideoProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// 可执行文件查找（测试注入）。
typedef VideoBinaryResolver = Future<String?> Function(String name);

/// 视频本地面：示例、脚本校验、机械对照与桌面渲染任务。
class VideoService {
  VideoService({
    VideoHost? host,
    Future<Directory> Function()? videosRoot,
    VideoProcessRunner? runner,
    VideoBinaryResolver? binaryResolver,
  })  : host = host ?? VideoHost.current(),
        // ignore: prefer_initializing_formals — 私有字段不能用命名形参初始化
        _videosRoot = videosRoot,
        _runner = runner ?? _defaultRunner,
        _binaryResolver = binaryResolver ?? _defaultBinaryResolver;

  /// 共享实例（视图切换即 dispose，但渲染任务与产物要活过切换）。
  static final VideoService instance = VideoService();

  /// 这台主机（渲染能力判据）。
  final VideoHost host;

  final Future<Directory> Function()? _videosRoot;
  final VideoProcessRunner _runner;
  final VideoBinaryResolver _binaryResolver;

  final Map<String, VideoRenderJob> _jobs = <String, VideoRenderJob>{};
  final Set<String> _cancelled = <String>{};
  VideoBinaries? _binaries;
  int _sequence = 0;

  /// 内置示例定义。
  List<VideoSampleInfo> get samples => videoSamples;

  /// 读取一个内置示例（内嵌常量，离线可用）。
  VideoDocument loadSample(int index) {
    if (index < 0 || index >= videoSamples.length) {
      throw const VideoRejected('sample_missing', 'index out of range');
    }
    final sample = videoSamples[index];
    final Map<String, dynamic> timeline;
    final Map<String, dynamic> spec;
    try {
      timeline = Map<String, dynamic>.from(jsonDecode(sample.timelineJson) as Map);
      spec = Map<String, dynamic>.from(jsonDecode(sample.specJson) as Map);
    } catch (error) {
      throw VideoRejected('sample_missing', '$error');
    }
    return VideoDocument.build(timeline: timeline, spec: spec);
  }

  /// 对照检查（不渲染）。规范问题直接判失败；未知符号聚合上报。
  VideoReviewResult review({
    required Map<String, dynamic> timeline,
    required Map<String, dynamic>? spec,
    int samples = 6,
  }) =>
      reviewVideoScript(timeline: timeline, spec: spec, samples: samples);

  /// 已有任务快照（未知任务返回 null）。
  VideoRenderJob? job(String id) => _jobs[id];

  /// 取消一个在飞任务（帧间检查，最迟下一帧停下）。
  void cancel(String id) {
    if (_jobs[id]?.isRunning ?? false) {
      _cancelled.add(id);
    }
  }

  /// 探测外部程序（结果缓存）。
  Future<VideoBinaries> resolveBinaries() async {
    final cached = _binaries;
    if (cached != null) return cached;
    String? rasterizer;
    VideoRasterizerKind? kind;
    for (final candidate in const ['resvg', 'rsvg-convert']) {
      final path = await _binaryResolver(candidate);
      if (path != null && path.isNotEmpty) {
        rasterizer = path;
        kind = candidate == 'resvg' ? VideoRasterizerKind.resvg : VideoRasterizerKind.rsvgConvert;
        break;
      }
    }
    final encoder = await _binaryResolver('ffmpeg');
    final resolved = VideoBinaries(
      rasterizer: rasterizer,
      rasterizerKind: kind,
      encoder: (encoder != null && encoder.isNotEmpty) ? encoder : null,
    );
    _binaries = resolved;
    return resolved;
  }

  /// 清空探测缓存（用户装了程序后重试）。
  void resetBinaryProbe() {
    _binaries = null;
  }

  /// 创建并启动一个渲染任务。
  ///
  /// 校验与二进制探测先做完（失败直接 throw [VideoRejected]，界面当场提示），
  /// 之后任务在后台推进，进度经 [job] 轮询。
  Future<VideoRenderJob> startRender(
    VideoDocument document, {
    int? fps,
    bool keepSvg = false,
  }) async {
    if (!host.isDesktop) {
      throw VideoRejected('render_desktop_only', 'host=${host.name}');
    }
    final rate = fps ?? document.fps;
    if (rate <= 0) {
      throw VideoRejected('no_frames', 'fps=$rate');
    }
    final frames = document.frameCount(rate);
    if (frames <= 0) {
      throw VideoRejected('no_frames', 'frames=$frames');
    }
    final binaries = await resolveBinaries();
    if (binaries.rasterizer == null || binaries.rasterizerKind == null) {
      // 组件缺失不缓存死结论：用户装好后重试要能重新探测。
      resetBinaryProbe();
      throw const VideoRejected('rasterizer_missing', 'resvg / rsvg-convert not found');
    }
    if (binaries.encoder == null) {
      resetBinaryProbe();
      throw const VideoRejected('encoder_missing', 'ffmpeg not found');
    }

    final root = await _resolveVideosRoot();
    _sequence += 1;
    final id = 'video-${DateTime.now().millisecondsSinceEpoch}-$_sequence';
    final directory = Directory('${root.path}/$id')..createSync(recursive: true);
    final job = VideoRenderJob(
      id: id,
      status: VideoJobStatus.running,
      fps: rate,
      frames: 0,
      totalFrames: frames,
      totalSeconds: document.totalSeconds,
      directory: directory.path,
    );
    _jobs[id] = job;
    unawaited(_run(job, document, binaries, directory, keepSvg));
    return job;
  }

  Future<Directory> _resolveVideosRoot() async {
    final custom = _videosRoot;
    if (custom != null) {
      final dir = await custom();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    // 与艺术架/作品集同一真源（AppPaths.projectsRoot()/videos）——此前这里
    // 用 $HOME/NoNDesign/videos，产物根本不会出现在作品集的视频架上。
    final dir = Directory('${(await AppPaths.projectsRoot()).path}/videos');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _run(
    VideoRenderJob initial,
    VideoDocument document,
    VideoBinaries binaries,
    Directory directory,
    bool keepSvg,
  ) async {
    var job = initial;
    final log = StringBuffer();
    void record(String line) {
      if (line.trim().isEmpty) return;
      log.writeln(line.trim());
      if (log.length > 6000) {
        final text = log.toString();
        log
          ..clear()
          ..write(text.substring(text.length - 4000));
      }
    }

    try {
      for (var frame = 0; frame < job.totalFrames; frame++) {
        if (_cancelled.remove(job.id)) {
          job = job.copyWith(status: VideoJobStatus.cancelled, log: log.toString());
          _jobs[job.id] = job;
          return;
        }
        final time = frame / job.fps;
        final svg = document.frameSvg(time);
        final base = '${directory.path}/frame_${frame.toString().padLeft(5, '0')}';
        final svgFile = File('$base.svg')..writeAsStringSync(svg);
        final pngFile = File('$base.png');
        final outcome = await _rasterize(
          binaries,
          svgFile,
          pngFile,
          document.width,
          document.height,
        );
        if (outcome.exitCode != 0 || !pngFile.existsSync()) {
          record(outcome.stderr.toString());
          throw VideoRejected(
            'render_failed',
            'rasterizer exit ${outcome.exitCode} at frame $frame',
          );
        }
        if (!keepSvg) {
          svgFile.deleteSync();
        }
        job = job.copyWith(frames: frame + 1, log: log.toString());
        _jobs[job.id] = job;
      }

      final mp4 = File('${directory.path}/frames.mp4');
      final result = await _runner(binaries.encoder!, <String>[
        '-y',
        '-loglevel',
        'error',
        '-framerate',
        '${job.fps}',
        '-i',
        '${directory.path}/frame_%05d.png',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        mp4.path,
      ]);
      record(result.stderr.toString());
      if (result.exitCode != 0 || !mp4.existsSync()) {
        throw VideoRejected('render_failed', 'encoder exit ${result.exitCode}');
      }
      job = job.copyWith(
        status: VideoJobStatus.done,
        mp4Path: mp4.path,
        frames: job.totalFrames,
        log: log.toString(),
      );
      _jobs[job.id] = job;
      _pruneOldJobs(directory.parent);
    } on VideoRejected catch (error) {
      record(error.technical);
      job = job.copyWith(
        status: VideoJobStatus.failed,
        failureCode: error.code,
        log: log.toString(),
      );
      _jobs[job.id] = job;
      _discardFailedFrames(directory);
    } catch (error) {
      record('$error');
      job = job.copyWith(
        status: VideoJobStatus.failed,
        failureCode: 'render_failed',
        log: log.toString(),
      );
      _jobs[job.id] = job;
      _discardFailedFrames(directory);
    }
  }

  /// 失败任务的帧是废纸（没有 mp4 可播）：把 PNG/SVG 清掉，目录留给日志，
  /// 不留 100+ 张孤儿 PNG 占着艺术架的坑。
  void _discardFailedFrames(Directory directory) {
    try {
      if (!directory.existsSync()) return;
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (lower.endsWith('.png') || lower.endsWith('.svg')) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<ProcessResult> _rasterize(
    VideoBinaries binaries,
    File svg,
    File png,
    int width,
    int height,
  ) {
    final executable = binaries.rasterizer!;
    final args = binaries.rasterizerKind == VideoRasterizerKind.resvg
        ? <String>[svg.path, png.path, '--width', '$width', '--height', '$height']
        : <String>['-w', '$width', '-h', '$height', '-o', png.path, svg.path];
    return _runner(executable, args);
  }

  /// 只保留最近 8 个任务目录（历史产物会一直躺在艺术架里，但磁盘不能无限长）。
  void _pruneOldJobs(Directory videosRoot) {
    try {
      final dirs = videosRoot
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((dir) => dir.path.split(Platform.pathSeparator).last.startsWith('video-'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final stale in dirs.skip(8)) {
        try {
          stale.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<ProcessResult> _defaultRunner(String executable, List<String> arguments) =>
      Process.run(executable, arguments);

  /// GUI 应用拿到的是精简 PATH（macOS 下通常只有 /usr/bin:/bin…），homebrew
  /// /cargo 装的 ffmpeg、resvg 用 `which` 根本探不到——发布包「视频工作台」
  /// 因此在装好了工具的机器上仍然报「找不到编码器」。`which` 失败后补扫这些
  /// 常见安装位置（首个存在且带可执行位的候选直接采用）。
  static const List<String> _binaryFallbackDirs = <String>[
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
    '/opt/local/bin',
  ];

  static Future<String?> _defaultBinaryResolver(String name) async {
    try {
      final result = Platform.isWindows
          ? await Process.run('where', <String>[name])
          : await Process.run('which', <String>[name]);
      if (result.exitCode == 0) {
        final first = result.stdout.toString().split('\n').first.trim();
        if (first.isNotEmpty) return first;
      }
    } catch (_) {}
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ?? '';
      for (final dir in <String>[
        if (profile.isNotEmpty) '$profile\\scoop\\shims',
        if (profile.isNotEmpty)
          '$profile\\AppData\\Local\\Microsoft\\WindowsApps',
      ]) {
        final candidate = File('$dir/$name.exe');
        if (candidate.existsSync()) return candidate.path;
      }
      return null;
    }
    final home = Platform.environment['HOME'] ?? '';
    final dirs = <String>[
      ..._binaryFallbackDirs,
      if (home.isNotEmpty) '$home/.cargo/bin',
    ];
    for (final dir in dirs) {
      final candidate = File('$dir/$name');
      try {
        final stat = candidate.statSync();
        // 存在 + 任意可执行位（rwx 任一），排除同名非可执行文件。
        if ((stat.mode & 0x49) != 0) return candidate.path;
      } catch (_) {}
    }
    return null;
  }

  static String _desktopDocumentsRoot() {
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) return profile;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return home;
    return Directory.systemTemp.path;
  }
}

// ---------------------------------------------------------------------------
// 本机文件动作
// ---------------------------------------------------------------------------

/// 在系统文件管理器中定位一个文件（桌面三平台）。
///
/// 调用方必须先问平台能力（[PlatformCapabilities.supportsRevealInFolder] /
/// 能力中心），移动端不出现这个入口。`Process.run` 在移动端必抛异常，这里的
/// 兜底返回 false 只是防御，不是可用性判据。
Future<bool> revealInSystemFileManager(String path) async {
  if (!VideoHost.current().isDesktop) return false;
  try {
    if (Platform.isMacOS) {
      await Process.run('open', <String>['-R', path]);
    } else if (Platform.isWindows) {
      // explorer 命中成功也常返回非 0（退出码语义不可靠），不读 exitCode。
      await Process.run('explorer', <String>['/select,$path']);
    } else {
      await Process.run('xdg-open', <String>[File(path).parent.path]);
    }
    return true;
  } catch (_) {
    // 找不到可执行文件 / 被沙箱拦 / 路径已消失：一律降级为「做不到」。
    return false;
  }
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

String _escape(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// 文本模板替换：支持 `{:.2f}` / `{:.0f}` / `{}` / `{:d}` 与前后缀文本。
///
/// 默认（没有 format）按旧管线的 `{:.2f}` 处理。
String _formatValue(double value, Object? format) {
  final template = format is String && format.isNotEmpty ? format : '{:.2f}';
  final matches = RegExp(r'\{[^{}]*\}').allMatches(template).toList();
  if (matches.isEmpty) return template;
  final out = StringBuffer();
  var last = 0;
  for (final match in matches) {
    out.write(template.substring(last, match.start));
    out.write(_formatOne(value, match.group(0)!));
    last = match.end;
  }
  out.write(template.substring(last));
  return out.toString();
}

String _formatOne(double value, String token) {
  final inner = token.substring(1, token.length - 1).trim();
  if (inner.isEmpty || inner == ':') return _trimNumber(value);
  final precision = RegExp(r'\.(\d+)f$').firstMatch(inner);
  if (precision != null) {
    return value.toStringAsFixed(int.parse(precision.group(1)!));
  }
  if (inner == ':d') return value.round().toString();
  return _trimNumber(value);
}

String _trimNumber(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

List<Map<String, dynamic>> _scenes(Map<String, dynamic> timeline) {
  final scenes = timeline['scenes'];
  if (scenes is! List) return const <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final scene in scenes)
      if (scene is Map) Map<String, dynamic>.from(scene),
  ];
}

List<Map<String, dynamic>> _elements(Map<String, dynamic> scene) {
  final elements = scene['elements'];
  if (elements is! List) return const <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final element in elements)
      if (element is Map) Map<String, dynamic>.from(element),
  ];
}

double _totalSecondsOf(Map<String, dynamic> timeline) {
  final scenes = timeline['scenes'];
  if (scenes is! List) return 0;
  var total = 0.0;
  for (final scene in scenes) {
    if (scene is Map) {
      final duration = scene['duration'];
      if (duration is num) total += duration.toDouble();
    }
  }
  return total;
}

double _doubleOf(Object? value, double fallback) =>
    value is num ? value.toDouble() : fallback;

int _intOf(Object? value, int fallback) => value is num ? value.toInt() : fallback;

String _stringOf(Object? value, String fallback) =>
    value is String ? value : fallback;
