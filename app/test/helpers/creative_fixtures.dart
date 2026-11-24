import 'dart:convert';
import 'dart:io';

/// 读取 `test/fixtures/creative/<name>` 的 JSON 对象。
///
/// flutter test 的工作目录是 `app/`；fixture 与测试同仓，缺文件直接抛错
/// （避免「断言没跑到」被误当成通过）。
Map<String, dynamic> creativeFixture(String name) {
  final File file = File('test/fixtures/creative/$name');
  if (!file.existsSync()) {
    throw StateError(
      'missing creative fixture: ${file.path}（cwd=${Directory.current.path}）',
    );
  }
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('creative fixture is not a JSON object: ${file.path}');
  }
  return decoded;
}

/// 深拷贝一份 fixture，供「只改一个字段」的负例测试使用。
Map<String, dynamic> creativeFixtureCopy(String name) {
  final Map<String, dynamic> raw = creativeFixture(name);
  return jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
}
