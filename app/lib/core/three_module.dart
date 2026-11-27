/// three.js 渲染库（r160）源码 → 可内联进单文件页面的命名空间对象。
///
/// 唯一实现：3D 建模预览页与 3D 视频预览页共用同一份改写逻辑（改一处两边都变），
/// 免得两份「看起来一样」的正则在字节锁定产物上漂移。
///
/// 纯 Dart：不读资源、不碰 Flutter。调用方负责把资源文本读进来
/// （`threeModuleAssetKey` 是 `assets/three/three.module.js`）。
library;

/// 渲染库资源键（发布包必须随包；`.gitattributes` 对该目录标 `-text`，
/// 保证字节数与 sha256 不被换行符漂移）。
///
/// 唯一来源：`three_service.dart` 的 `threeModuleAssetKey` 与 3D 视频预览面
/// 都引用这里，两个页面版本读的是同一份产物。
const String threeModuleAssetKeyPath = 'assets/three/three.module.js';

/// 改写失败：源码形状与 r160 的约定不符（缺出口块 / 出口块为空）。
///
/// 调用方各自翻译成自己的失败码（3D 建模 → `asset_missing`；3D 视频 →
/// `video3d_three_module_invalid`），本层不依赖任何上层错误类型。
final class ThreeModuleRewriteError implements Exception {
  const ThreeModuleRewriteError(this.message);

  final String message;

  @override
  String toString() => 'ThreeModuleRewriteError($message)';
}

/// r160 的 `three.module.js` 只有**一条**收尾的 `export { A, B, ... };`，没有
/// `import`。把这条出口语句改写成 `const THREE = { A, B, ... };` 之后，整份源码
/// 就是一个合法的内联模块：既保留内部作用域，又把全部出口聚成一个可直接传给
/// 场景构建函数的对象——不需要 importmap，也不需要在 `file://` 下取第二个文件。
String threeModuleNamespaceSource(String source) {
  final List<RegExpMatch> matches = RegExp(
    r'export\s*\{([\s\S]*?)\}\s*;?\s*$',
  ).allMatches(source).toList();
  if (matches.isEmpty) {
    throw const ThreeModuleRewriteError(
      'three.module.js: no export block at the end',
    );
  }
  final RegExpMatch block = matches.last;
  final List<String> names = block
      .group(1)!
      .split(',')
      .map((String name) => name.trim())
      .where((String name) => name.isNotEmpty)
      .toList();
  if (names.isEmpty) {
    throw const ThreeModuleRewriteError(
      'three.module.js: empty export block',
    );
  }
  final List<String> entries = <String>[];
  for (final String name in names) {
    final List<String> alias = name.split(RegExp(r'\s+as\s+'));
    entries.add(
      alias.length == 2 ? '${alias[1].trim()}: ${alias[0].trim()}' : name,
    );
  }
  final String replacement =
      'const THREE = {\n${entries.map((String e) => '  $e,').join('\n')}\n};\n';
  return source.replaceRange(block.start, block.end, replacement);
}
