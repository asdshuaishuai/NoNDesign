// 纯 Dart SHA-256（FIPS 180-4）。
//
// 为什么自己写而不加 `crypto` 依赖：模型校验那条线（N6/M1）只需要 SHA-256
// 一个原语，而本轮依赖纪律是「新增依赖只有四个 mediapipe 包」——`crypto`
// 目前只是 mediapipe_core 的传递依赖，直接 import 会触发
// `depend_on_referenced_packages` 且把传递依赖当 API 用。实现有单测锚定
// 标准测试向量（空串 / "abc" / 56 字节 / 100 万字节）。
//
// 流式：模型 388 MB 不能整份读进内存，[sha256File] 按 64 KiB 块喂给
// [Sha256Digest.add]。
import 'dart:io';
import 'dart:typed_data';

/// SHA-256 轮常量（前 64 个素数立方根小数部分的前 32 位）。
const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const List<int> _initial = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const int _mask32 = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask32;

/// 增量 SHA-256：可以多次 [add]，最后一次 [close] 取 hex 摘要。
///
/// 实例只能 close 一次；close 之后再 add 抛 [StateError]。
class Sha256Digest {
  final List<int> _h = List<int>.of(_initial);
  final Uint8List _buffer = Uint8List(64);
  int _bufferLength = 0;
  int _totalBytes = 0;
  bool _closed = false;

  /// 喂入 [data]（任意长度；内部按 64 字节块压缩）。
  void add(List<int> data) {
    if (_closed) {
      throw StateError('Sha256Digest is closed');
    }
    _totalBytes += data.length;
    var offset = 0;
    if (_bufferLength > 0) {
      final take = (64 - _bufferLength) < data.length
          ? (64 - _bufferLength)
          : data.length;
      _buffer.setRange(_bufferLength, _bufferLength + take, data);
      _bufferLength += take;
      offset = take;
      if (_bufferLength == 64) {
        _compress(_buffer, 0);
        _bufferLength = 0;
      }
    }
    while (data.length - offset >= 64) {
      _compress(data, offset);
      offset += 64;
    }
    final rest = data.length - offset;
    if (rest > 0) {
      _buffer.setRange(0, rest, data, offset);
      _bufferLength = rest;
    }
  }

  /// 收尾（填充 + 长度）并返回小写 hex 摘要。只能调用一次。
  String close() {
    if (_closed) {
      throw StateError('Sha256Digest is closed');
    }
    _closed = true;
    final bitLength = _totalBytes * 8;
    // 填充：0x80 + 若干 0x00 使 (64 - (len % 64)) == 8，再附 64 位大端长度。
    final padLength = (_bufferLength < 56) ? 56 - _bufferLength : 120 - _bufferLength;
    final padding = Uint8List(padLength + 8);
    padding[0] = 0x80;
    final lengthView = ByteData.sublistView(padding, padLength);
    lengthView.setUint32(0, (bitLength >> 32) & _mask32);
    lengthView.setUint32(4, bitLength & _mask32);
    // add 会更新 _totalBytes，这里直接用内部块压缩绕过计数。
    _addFinal(padding);

    final out = StringBuffer();
    for (final word in _h) {
      out.write(word.toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }

  /// 收尾专用：不再累计长度，只做块压缩（padding 已按原始长度构造）。
  void _addFinal(List<int> data) {
    var offset = 0;
    if (_bufferLength > 0) {
      final take = (64 - _bufferLength) < data.length
          ? (64 - _bufferLength)
          : data.length;
      _buffer.setRange(_bufferLength, _bufferLength + take, data);
      _bufferLength += take;
      offset = take;
      if (_bufferLength == 64) {
        _compress(_buffer, 0);
        _bufferLength = 0;
      }
    }
    while (data.length - offset >= 64) {
      _compress(data, offset);
      offset += 64;
    }
    final rest = data.length - offset;
    if (rest > 0) {
      _buffer.setRange(0, rest, data, offset);
      _bufferLength = rest;
    }
  }

  void _compress(List<int> block, int offset) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (block[j] << 24) |
          (block[j + 1] << 16) |
          (block[j + 2] << 8) |
          block[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }
    var a = _h[0];
    var b = _h[1];
    var c = _h[2];
    var d = _h[3];
    var e = _h[4];
    var f = _h[5];
    var g = _h[6];
    var h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _mask32) & g);
      final temp1 = (h + s1 + ch + _k[i] + w[i]) & _mask32;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & _mask32;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _mask32;
    }
    _h[0] = (_h[0] + a) & _mask32;
    _h[1] = (_h[1] + b) & _mask32;
    _h[2] = (_h[2] + c) & _mask32;
    _h[3] = (_h[3] + d) & _mask32;
    _h[4] = (_h[4] + e) & _mask32;
    _h[5] = (_h[5] + f) & _mask32;
    _h[6] = (_h[6] + g) & _mask32;
    _h[7] = (_h[7] + h) & _mask32;
  }
}

/// 一段内存字节的 SHA-256 hex（小文件/短文本用）。
String sha256Hex(List<int> bytes) {
  final digest = Sha256Digest()..add(bytes);
  return digest.close();
}

/// 文件内容的 SHA-256 hex（流式，64 KiB 块；模型动辄几百 MB）。
Future<String> sha256File(File file) async {
  final digest = Sha256Digest();
  await for (final chunk in file.openRead()) {
    digest.add(chunk);
  }
  return digest.close();
}
