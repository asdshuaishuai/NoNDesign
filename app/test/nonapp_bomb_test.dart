// 解压炸弹回归（res-1）：高压缩比 + 伪造声明大小的 `.nonapp` 包。
//
// `NonAppPackage.parse` 的声明大小预检基于 zip 头部（可伪造）；真实解压
// 必须走有界流式解码并累计真实输出，否则把 64MiB 零字节压成几十 KB、
// 头部声明 1000 的包会在长度校验前把整段数据解进内存。
//
// 夹具构造：dart:io 的分块 raw deflate 编码器把 64MiB 零字节压成 ~64KB，
// 再以「已压缩条目」直通写入 zip（归档声明大小保留 1000）。测试本身不物化
// 64MiB 明文。archive 4 的 ArchiveFile.file + 自定义 FileContent 让
// ZipEncoder 原样搬运压缩流（不走重复压缩）。
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/nonapp_package.dart';

/// 已压缩内容（raw deflate）：ZipEncoder 对 `isCompressed` 条目原样写入。
class _RawDeflateContent extends FileContent {
  _RawDeflateContent(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  bool get isCompressed => true;

  @override
  InputStream getStream({bool decompress = true}) => InputMemoryStream(bytes);

  @override
  void write(OutputStream output) => output.writeBytes(bytes);

  @override
  void decompress(OutputStream output) => output.writeBytes(bytes);

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}
}

class _CollectSink implements Sink<List<int>> {
  _CollectSink(this._builder);

  final BytesBuilder _builder;

  @override
  void add(List<int> data) => _builder.add(data);

  @override
  void close() {}
}

/// 分块 raw deflate：1MiB 零块循环喂入，输出只留压缩产物。
Uint8List _deflateZeros(int totalBytes) {
  final out = BytesBuilder(copy: false);
  final encoder = io.ZLibEncoder(raw: true, level: 9)
      .startChunkedConversion(_CollectSink(out));
  final zeros = Uint8List(1024 * 1024);
  for (var i = 0; i < totalBytes ~/ zeros.length; i++) {
    encoder.add(zeros);
  }
  encoder.close();
  return out.takeBytes();
}

/// 炸弹包：真实载荷 64MiB 零字节，payload/index.html 声明 1000 字节。
List<int> _bombPackage({
  int payloadBytes = 64 * 1024 * 1024,
  int declaredBytes = 1000,
}) {
  final archive = Archive();
  archive.add(ArchiveFile.string(
    'manifest.json',
    jsonEncode({
      'formatVersion': 1,
      'id': 'bomb-app',
      'name': 'bomb-app',
      'title': '炸弹',
      'renderer': 'html',
      'createdAt': 1700000000,
      'minAppVersion': '0.1.0',
    }),
  ));
  final bomb = ArchiveFile.file(
    'payload/index.html',
    declaredBytes,
    _RawDeflateContent(_deflateZeros(payloadBytes)),
  )..compression = CompressionType.deflate;
  archive.add(bomb);
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  test('高压缩比炸弹：声明 1000 字节的 64MiB 载荷在真实输出超限时被拒', () {
    final bytes = _bombPackage();
    // 包体本身很小（高压缩比），声明大小 1000 < 8MiB——两项快速预检都放行，
    // 只有真实解压计数能拦住它。
    expect(bytes.length, lessThan(512 * 1024));

    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    final bomb = archive.files.firstWhere((f) => f.name == 'payload/index.html');
    expect(bomb.size, 1000, reason: '声明大小必须是伪造的小值（预检放行）');
    expect(bomb.compression, CompressionType.deflate);

    final rssBefore = io.ProcessInfo.currentRss;
    expect(
      () => NonAppPackage.parse(bytes),
      throwsA(isA<NonAppException>()
          .having((e) => e.code, 'code', 'nonapp_too_large')
          .having((e) => e.message, 'message', contains('解压后超过 8MiB'))),
      reason: '真实解压超过 MAX_ENTRY_BYTES 必须 fail-closed',
    );
    // 峰值内存不随真实载荷线性增长：有界流式解码最多到 8MiB 输出上限即停。
    final rssDelta = io.ProcessInfo.currentRss - rssBefore;
    expect(rssDelta, lessThan(48 * 1024 * 1024),
        reason: '解压峰值必须远低于真实载荷（实测 ${(rssDelta / 1024 / 1024).toStringAsFixed(1)}MiB）');
  });

  test('正常压缩条目仍可解析（有界流式 inflate 不回退正确性）', () {
    final archive = Archive();
    archive.add(ArchiveFile.string(
      'manifest.json',
      jsonEncode({
        'formatVersion': 1,
        'id': 'plain-app',
        'name': 'plain-app',
        'title': '普通应用',
        'renderer': 'html',
        'createdAt': 1700000000,
        'minAppVersion': '0.1.0',
      }),
    ));
    final html = '<!doctype html><html><head><style>body{background:#111;color:#eee}'
        'canvas{display:block;width:100%;height:60vh}</style></head>'
        '<body><canvas id=c></canvas><div>plain-marker</div>'
        '<script>const c=document.getElementById("c");'
        'const x=c.getContext("2d");function f(){x.clearRect(0,0,9,9);'
        'requestAnimationFrame(f);}f();</script></body></html>';
    archive.add(ArchiveFile.string('payload/index.html', html));

    final pkg = NonAppPackage.parse(ZipEncoder().encodeBytes(archive));
    expect(pkg.renderer, 'html');
    expect(utf8.decode(pkg.htmlBytes!), contains('plain-marker'));
  });
}
