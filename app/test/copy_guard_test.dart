// Copy guard (batch 01).
//
// Static scan of user-visible strings in `app/lib/**/*.dart`. The glossary in
// `docs/copy-glossary.md` is the source of truth; this test makes violations
// visible and, in strict mode, fatal.
//
//   baseline (default):        flutter test test/copy_guard_test.dart
//   strict (batches 13/15):    flutter test --dart-define=COPY_GUARD_STRICT=true test/copy_guard_test.dart
//
// What is scanned: string literals that reach the screen through
//   Text / SelectableText / Semantics / Pill / TextSpan / RichText / SnackBar /
//   AlertDialog / Tooltip / _toast / _snack / showToast / toast
// and through named parameters `label`, `title`, `subtitle`, `hintText`,
// `helperText`, `labelText`, `errorText`, `semanticLabel`, `tooltip`.
//
// What is NOT scanned: prompts passed to models, comments, and tests — they are
// not user-visible copy, so they never enter the scan surface (no allowlist
// file is used).
//
// Two rule sets:
//  1. internal jargon (python / wasm / moonviz / ddp / mbt / canonical / acp /
//     agentgate / server / localhost / 端口 / sqlite / resvg / ffmpeg / …);
//  2. bare error codes: a user-visible string that is nothing but
//     `snake_case_words` (`^[a-z0-9]+(_[a-z0-9]+)+$`) belongs in a collapsed
//     technical-details block, not on screen.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

class StringLit {
  final int start;
  final int end;
  final String value;

  const StringLit(this.start, this.end, this.value);
}

class SourceScan {
  /// Source with comment characters blanked out (same length → same offsets).
  final String stripped;
  final List<StringLit> literals;
  final List<int> lineStarts;

  const SourceScan(this.stripped, this.literals, this.lineStarts);

  int lineOf(int offset) {
    var lo = 0;
    var hi = lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }
}

bool _isIdentChar(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24;

/// Scans Dart source once, returning comment-free text plus string literals.
SourceScan scanSource(String source) {
  final out = StringBuffer();
  final literals = <StringLit>[];
  // Line starts come from the original source; offsets are preserved.
  final lineStarts = <int>[0];
  for (var k = 0; k < source.length; k++) {
    if (source[k] == '\n') lineStarts.add(k + 1);
  }
  var i = 0;

  void keepTo(int next) {
    out.write(source.substring(i, next));
    i = next;
  }

  void blankTo(int next) {
    for (var k = i; k < next; k++) {
      out.write(source[k] == '\n' ? '\n' : ' ');
    }
    i = next;
  }

  // Skips a string starting at [start] (opening quote); returns the index just
  // past the closing quote and records the literal.
  int skipString(int start, {required bool raw, required String quote, required bool triple}) {
    final q = quote;
    final delimiter = triple ? q * 3 : q;
    var k = start + delimiter.length;
    while (k < source.length) {
      if (!raw && source[k] == r'\') {
        k += 2;
        continue;
      }
      if (!triple && source[k] == '\n') {
        break; // unterminated single-line string: be forgiving
      }
      if (source.startsWith(delimiter, k)) {
        final value = source.substring(start + delimiter.length, k);
        literals.add(StringLit(start, k + delimiter.length, value));
        return k + delimiter.length;
      }
      // ${...} interpolation may itself contain quotes; skip it wholly.
      if (!raw && source[k] == r'$' && k + 1 < source.length && source[k + 1] == '{') {
        k = _skipInterpolation(source, k + 2);
        continue;
      }
      k++;
    }
    literals.add(StringLit(start, source.length, source.substring(start + delimiter.length)));
    return source.length;
  }

  while (i < source.length) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      var e = source.indexOf('\n', i);
      if (e < 0) e = source.length;
      blankTo(e);
      continue;
    }
    if (c == '/' && next == '*') {
      final e = source.indexOf('*/', i + 2);
      blankTo(e < 0 ? source.length : e + 2);
      continue;
    }
    if (c == r'$' && next == '{') {
      final e = _skipInterpolation(source, i + 2);
      keepTo(e);
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = source.startsWith(c * 3, i);
      final raw = i > 0 && source[i - 1] == 'r' && (i < 2 || !_isIdentChar(source.codeUnitAt(i - 2)));
      final e = skipString(i, raw: raw, quote: c, triple: triple);
      keepTo(e);
      continue;
    }
    out.write(c);
    i++;
  }
  return SourceScan(out.toString(), literals, lineStarts);
}

int _skipInterpolation(String source, int start) {
  var depth = 1;
  var k = start;
  while (k < source.length) {
    final c = source[k];
    if (c == "'" || c == '"') {
      final triple = source.startsWith(c * 3, k);
      final raw = k > 0 && source[k - 1] == 'r' && (k < 2 || !_isIdentChar(source.codeUnitAt(k - 1)));
      final delim = triple ? c * 3 : c;
      k += delim.length;
      while (k < source.length) {
        if (!raw && source[k] == r'\') {
          k += 2;
          continue;
        }
        if (source.startsWith(delim, k)) {
          k += delim.length;
          break;
        }
        k++;
      }
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return k + 1;
    }
    k++;
  }
  return k;
}

const List<String> _callTriggers = [
  'Text',
  'SelectableText',
  'Semantics',
  'Pill',
  'TextSpan',
  'RichText',
  'SnackBar',
  'AlertDialog',
  'Tooltip',
  '_toast',
  '_snack',
  'showToast',
  'toast',
];

const List<String> _paramTriggers = [
  'label',
  'title',
  'subtitle',
  'hintText',
  'helperText',
  'labelText',
  'errorText',
  'semanticLabel',
  'tooltip',
];

class Finding {
  final int line;
  final String literal;
  final String term;

  const Finding(this.line, this.literal, this.term);

  @override
  String toString() => 'line $line: "$literal"  ← $term';
}

/// Returns every jargon / bare-error-code finding in [source].
List<Finding> findCopyViolations(String source, {Iterable<String> ignoreFiles = const []}) {
  final scan = scanSource(source);
  final code = scan.stripped;
  final findings = <Finding>[];
  final seen = <String>{};

  void inspect(int start, int end) {
    for (final lit in scan.literals) {
      if (lit.start < start || lit.end > end) continue;
      if (!seen.add('${lit.start}')) continue;
      final term = _violationTerm(lit.value);
      if (term != null) findings.add(Finding(scan.lineOf(lit.start), lit.value, term));
    }
  }

  for (final trigger in _callTriggers) {
    final re = RegExp('\\b${RegExp.escape(trigger)}\\s*\\(');
    for (final m in re.allMatches(code)) {
      final open = code.indexOf('(', m.start);
      final close = _matching(code, open);
      if (close < 0) continue;
      inspect(open + 1, close);
    }
  }

  for (final param in _paramTriggers) {
    final re = RegExp('\\b${RegExp.escape(param)}\\s*:');
    for (final m in re.allMatches(code)) {
      final start = code.indexOf(':', m.start) + 1;
      final end = _valueEnd(code, start);
      inspect(start, end);
    }
  }

  findings.sort((a, b) => a.line.compareTo(b.line));
  return findings;
}

int _matching(String code, int openParen) {
  var depth = 0;
  for (var i = openParen; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

int _valueEnd(String code, int start) {
  var depth = 0;
  for (var i = start; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) return i;
      depth--;
    }
    if (c == ',' && depth == 0) return i;
    if (c == '\n' && depth == 0) {
      // Named params are usually single-line; allow trailing tokens but stop at
      // the end of the statement to avoid swallowing the next widget.
      final rest = code.substring(i).trimLeft();
      if (rest.startsWith(')') || rest.startsWith(']') || rest.startsWith('}')) return i;
    }
  }
  return code.length;
}

final List<(RegExp, String)> _banned = [
  (RegExp(r'\bpython\b', caseSensitive: false), 'python'),
  (RegExp(r'\bflutter\b', caseSensitive: false), 'flutter'),
  (RegExp(r'\bdart\b', caseSensitive: false), 'dart'),
  (RegExp(r'\bwasm\b', caseSensitive: false), 'wasm'),
  (RegExp(r'\bmoonviz\b', caseSensitive: false), 'moonviz'),
  (RegExp(r'\bddp\b', caseSensitive: false), 'ddp'),
  (RegExp(r'\bmbt\b', caseSensitive: false), 'mbt'),
  (RegExp(r'\bcanonical\b', caseSensitive: false), 'canonical'),
  (RegExp(r'\bacp\b', caseSensitive: false), 'acp'),
  (RegExp(r'\bagentgate\b', caseSensitive: false), 'agentgate'),
  (RegExp(r'\bserver\b', caseSensitive: false), 'server'),
  (RegExp(r'服务器'), '服务器'),
  (RegExp(r'桌面服务'), '桌面服务'),
  (RegExp(r'端口'), '端口'),
  (RegExp(r'\blocalhost\b', caseSensitive: false), 'localhost'),
  (RegExp(r'127\.0\.0\.1'), '127.0.0.1'),
  (RegExp(r'\bresvg\b', caseSensitive: false), 'resvg'),
  (RegExp(r'\bffmpeg\b', caseSensitive: false), 'ffmpeg'),
  (RegExp(r'\bblockout\b', caseSensitive: false), 'blockout'),
  (RegExp(r'refine-spec', caseSensitive: false), 'refine-spec'),
  (RegExp(r'\bsqlite\b', caseSensitive: false), 'sqlite'),
  (RegExp(r'models\.dev', caseSensitive: false), 'models.dev'),
  (RegExp(r'\bk=v\b', caseSensitive: false), 'k=v'),
  (RegExp(r'surfaceid', caseSensitive: false), 'surfaceId'),
  (RegExp(r'\ba2ui\b', caseSensitive: false), 'a2ui'),
  (RegExp(r'\bnonapp\b', caseSensitive: false), 'nonapp'),
  (RegExp(r'\.nonapp', caseSensitive: false), '.nonapp'),
  (RegExp(r'\bjsonl\b', caseSensitive: false), 'jsonl'),
  (RegExp(r'\bengine_'), 'engine_* error code'),
  (RegExp(r'\bsession_[a-z]'), 'session_* export'),
  (RegExp(r'\btool_[a-z]'), 'tool_* name'),
  (RegExp(r'\bmbt_[a-z]'), 'mbt_* error code'),
  (RegExp(r'\bddp_[a-z]'), 'ddp_* error code'),
  (RegExp(r'\bwasm_[a-z]'), 'wasm_* error code'),
  (RegExp(r'\bagent_[a-z]'), 'agent_* internal name'),
  // 品牌只有 NaN（用户裁决 2026-11-18）：旧名 NoN / NoNDesign 不得出现在
  // 用户可见文案里（磁盘目录名、标识符、JS 桥不在扫描面内，见文案词表）。
  (RegExp(r'\bnon\b', caseSensitive: false), 'NoN 旧品牌（用 NaN）'),
  (RegExp(r'\bNoNDesign\b'), 'NoNDesign 旧品牌（用 NaN）'),
];

final RegExp _bareCode = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');

String? _violationTerm(String literal) {
  final text = literal.trim();
  if (text.isEmpty) return null;
  for (final (re, label) in _banned) {
    if (re.hasMatch(text)) return label;
  }
  if (_bareCode.hasMatch(text)) return 'bare error code';
  return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const bool _strict = bool.fromEnvironment('COPY_GUARD_STRICT');

Directory _appDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

void main() {
  test('scanner recognises jargon and bare error codes', () {
    const source = '''
// Text('server') in a comment is not user-visible
Widget broken() => Text('连接服务器失败');
Widget build() => Text('wasm 渲染失败');
Widget other() => TextField(decoration: InputDecoration(hintText: 'engine_unavailable'));
Widget clean() => Text('检查连接');
''';
    final findings = findCopyViolations(source);
    expect(findings.map((f) => f.term).toList(), containsAll(['服务器', 'wasm', 'engine_* error code']));
    expect(findings.any((f) => f.literal == '检查连接'), isFalse);
    expect(findings.any((f) => f.literal == 'server'), isFalse, reason: 'comments are not scanned');
  });

  test('contract files introduced by batch 01 are copy-clean', () {
    final appDir = _appDir();
    for (final name in ['capability.dart', 'capability_hub.dart', 'layout.dart', 'platform_capabilities.dart']) {
      final file = File('${appDir.path}/lib/core/$name');
      final findings = findCopyViolations(file.readAsStringSync());
      expect(findings, isEmpty, reason: 'lib/core/$name: ${findings.join("; ")}');
    }
  });

  test('user-visible strings follow the copy glossary', () {
    final appDir = _appDir();
    final files = Directory('${appDir.path}/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final report = StringBuffer();
    var total = 0;
    for (final file in files) {
      final findings = findCopyViolations(file.readAsStringSync());
      if (findings.isEmpty) continue;
      total += findings.length;
      final rel = file.path.substring(appDir.path.length + 1);
      for (final finding in findings) {
        report.writeln('  $rel:${finding.line}  ${finding.term}  ← "${finding.literal}"');
      }
    }

    if (total == 0) {
      // ignore: avoid_print
      print('[copy-guard] clean: 0 findings across ${files.length} files');
      return;
    }
    // ignore: avoid_print
    print('[copy-guard] ${_strict ? "STRICT" : "baseline"} — $total findings');
    // ignore: avoid_print
    print(report.toString());
    if (_strict) {
      fail('$total user-visible strings violate docs/copy-glossary.md (strict mode)');
    }
  });
}
