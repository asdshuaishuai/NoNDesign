#!/usr/bin/env dart
// 3D 预览资产的同步 / 校验（批次 06）。
//
// 预览三件套必须**同目录**（WebKit 加载本地文件时的读取范围就是宿主页的
// 父目录），并且完全离线——页面里只允许相对路径，出现任何 CDN 域名即失败。
//
// 用法（仓库根执行，不需要 flutter，也不需要任何第三方包）：
//   dart scripts/sync_three_assets.dart            校验（默认）
//   dart scripts/sync_three_assets.dart --write    从候选源同步到 app/assets/three/
//   dart scripts/sync_three_assets.dart --print-sha
//
// 校验三件事：
//   1. app/assets/three/three.module.js 的 sha256 与字节数 == 锚点；
//   2. preview.html 与 three.module.js 在同一个目录，且模板带两个内联占位
//      （/*__THREE_MODULE__*/ 与 /*__SCENE_SOURCE__*/）——应用在挂载预览时
//      把两份源码填进去，生成字节自包含的页面（file:// 不允许模块取文件）；
//   3. preview.html 不引用远端地址（unpkg / jsdelivr / cdnjs / http(s)://）。
//
// 候选源（--write 时按顺序尝试，第一个 sha256 命中的被采用）：
//   server/three_vendor/three.module.js   （迁移期的原始 vendored 副本）
//   third_party/three/three.module.js     （若日后把渲染库提到 third_party）
//
// 退出码：0 = 通过，1 = 失败（drift / 缺文件 / 远端引用）。
import 'dart:io';
import 'dart:typed_data';

/// 渲染库锚点：r160，1,272,972 B。
const String pinnedSha256 =
    '76dea8151bc9352aef3528b4262e249b2604f62543828328db978d060d61a495';
const int pinnedBytes = 1272972;

const List<String> candidateSources = <String>[
  'server/three_vendor/three.module.js',
  'third_party/three/three.module.js',
];

/// 页面里出现即判失败（离线纪律）。
const List<String> remoteMarkers = <String>[
  'unpkg.com',
  'cdn.jsdelivr.net',
  'cdnjs.cloudflare.com',
  'https://',
  'http://',
];

String _join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

void main(List<String> args) {
  final root = _repoRoot();
  final assetsDir = _join(root, 'app/assets/three');
  final modulePath = _join(assetsDir, 'three.module.js');
  final previewPath = _join(assetsDir, 'preview.html');

  if (args.contains('--print-sha')) {
    final file = File(modulePath);
    if (!file.existsSync()) {
      stderr.writeln('[three-assets] missing: $modulePath');
      exit(1);
    }
    stdout.writeln(sha256Hex(file.readAsBytesSync()));
    return;
  }

  if (args.contains('--write')) {
    if (!_sync(root, modulePath)) exit(1);
  }

  final failures = <String>[];
  final module = File(modulePath);
  if (!module.existsSync()) {
    failures.add('缺少渲染库：$modulePath');
  } else {
    final bytes = module.readAsBytesSync();
    if (bytes.length != pinnedBytes) {
      failures.add('渲染库字节数漂移：${bytes.length} != $pinnedBytes');
    }
    final digest = sha256Hex(bytes);
    if (digest != pinnedSha256) {
      failures.add('渲染库 sha256 漂移：$digest != $pinnedSha256');
    }
  }

  final preview = File(previewPath);
  if (!preview.existsSync()) {
    failures.add('缺少预览宿主页：$previewPath');
  } else {
    final html = preview.readAsStringSync();
    for (final marker in remoteMarkers) {
      if (html.contains(marker)) {
        failures.add('预览页引用了远端地址（$marker）——预览必须离线');
      }
    }
    if (!html.contains('/*__THREE_MODULE__*/')) {
      failures.add('预览模板缺少渲染库内联占位 /*__THREE_MODULE__*/');
    }
    if (!html.contains('/*__SCENE_SOURCE__*/')) {
      failures.add('预览模板缺少场景内联占位 /*__SCENE_SOURCE__*/');
    }
    // 经典脚本在 <head> 里跑，错误节点必须已经在 body 里（曾经漏掉 <body>，
    // onerror 里 getElementById('err').textContent 直接抛 TypeError）。
    if (!html.contains('<body>') || !html.contains('id="err"')) {
      failures.add('预览模板缺少 <body> / #err 错误节点');
    }
  }

  if (failures.isEmpty) {
    stdout.writeln('[three-assets] ok: r160, $pinnedBytes B, sha256 ${pinnedSha256.substring(0, 12)}…');
    return;
  }
  for (final failure in failures) {
    stderr.writeln('[three-assets] $failure');
  }
  exit(1);
}

bool _sync(String root, String modulePath) {
  for (final relative in candidateSources) {
    final source = File(_join(root, relative));
    if (!source.existsSync()) continue;
    final bytes = source.readAsBytesSync();
    if (bytes.length != pinnedBytes || sha256Hex(bytes) != pinnedSha256) {
      stderr.writeln('[three-assets] 跳过 $relative：内容与锚点不符');
      continue;
    }
    final target = File(modulePath);
    target.parent.createSync(recursive: true);
    if (target.existsSync() && _sameBytes(target.readAsBytesSync(), bytes)) {
      stdout.writeln('[three-assets] 已是锚定产物（源：$relative）');
      return true;
    }
    target.writeAsBytesSync(bytes, flush: true);
    stdout.writeln('[three-assets] 已写入 $modulePath（源：$relative）');
    return true;
  }
  stderr.writeln('[three-assets] --write 失败：没有任何候选源与锚点一致（${candidateSources.join(", ")}）');
  return false;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory(_join(dir.path, 'app')).existsSync() &&
        Directory(_join(dir.path, 'scripts')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  stderr.writeln('[three-assets] 找不到仓库根（当前 ${Directory.current.path}）');
  exit(1);
}

// ---------------------------------------------------------------------------
// SHA-256（纯 Dart，零依赖——脚本要在没有 pub get 的仓库根也能跑）
// ---------------------------------------------------------------------------

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// 小写 hex 的 SHA-256。
String sha256Hex(List<int> message) {
  final state = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final padded = BytesBuilder(copy: false);
  padded.add(message);
  padded.addByte(0x80);
  final messageBytes = message.length;
  var padLength = (56 - (messageBytes + 1) % 64) % 64;
  if (padLength < 0) padLength += 64;
  padded.add(Uint8List(padLength));
  final lengthBytes = Uint8List(8);
  var bitLength = messageBytes * 8;
  for (var i = 7; i >= 0; i--) {
    lengthBytes[i] = bitLength & 0xff;
    bitLength >>= 8;
  }
  padded.add(lengthBytes);

  final data = padded.takeBytes();
  final w = Uint32List(64);
  for (var offset = 0; offset < data.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = state[0], b = state[1], c = state[2], d = state[3];
    var e = state[4], f = state[5], g = state[6], h = state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    state[0] = (state[0] + a) & 0xffffffff;
    state[1] = (state[1] + b) & 0xffffffff;
    state[2] = (state[2] + c) & 0xffffffff;
    state[3] = (state[3] + d) & 0xffffffff;
    state[4] = (state[4] + e) & 0xffffffff;
    state[5] = (state[5] + f) & 0xffffffff;
    state[6] = (state[6] + g) & 0xffffffff;
    state[7] = (state[7] + h) & 0xffffffff;
  }

  final out = StringBuffer();
  for (final word in state) {
    out.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}
