// `.nonapp` 包的服务端 API 扩展（api.dart 的 hotapp 方法组之外，独立文件
// 承载——import/export 的原始字节面不适合塞进 postJson/getJson 的 JSON 形状）。
//
// 端点（server/nonapp_routes.py）：
//   POST /hotapp/export   {name} → application/zip（**必须 POST**，与端点同法）
//   POST /hotapp/import   原始 zip body → {ok,name,title,renderer,id,formatVersion,dir,portfolio}
//   GET  /hotapp/info/{name} → {ok,name,title,renderer,exists}
//   GET  /hotapp/a2ui/{name} → {ok,name,title,messages:[…]}
//
// 字节面自建 http.Client：NoNDesignApi 的 `_client` 是私有字段（同库才可
// 见），而 api.dart 不在本路可改范围——每次调用建一个短命 client 并关闭，
// 与既有 SSE 方法的资源模型一致。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';

/// 导出结果：成功时 [bytes]/[filename] 有值，失败时 [error] 是服务端 detail。
/// 用 record 而不是「Map 里塞 Uint8List」：调用方必须显式区分三个字段。
typedef NonAppExportResult = ({List<int>? bytes, String? filename, String? error});

/// 测试/自定义传输注入点（生产代码不调用）。
///
/// `NoNDesignApi._client` 是私有字段（同库才可见），api.dart 又不在本路可改
/// 范围——字节面因此默认自建短命 client。widget 测试要断言「在线分支走了
/// /hotapp/import 而不是离线缓存」，就需要把这层换成 MockClient；用 Expando
/// 按 api 实例挂 client，避免全局可变状态在测试间串味。
final Expando<http.Client> _nonAppClients = Expando<http.Client>('nonapp.http');

void useNonAppHttpClient(NoNDesignApi api, http.Client? client) {
  if (client == null) {
    _nonAppClients[api] = null; // Expando 置 null 即移除
  } else {
    _nonAppClients[api] = client;
  }
}

/// 取本实例的传输：注入优先（不负责关闭），否则新建（调用方 finally 关闭）。
({http.Client client, bool owned}) _clientFor(NoNDesignApi api) {
  final injected = _nonAppClients[api];
  if (injected != null) return (client: injected, owned: false);
  return (client: http.Client(), owned: true);
}

extension NonAppApi on NoNDesignApi {
  /// 应用 → `.nonapp` 字节（**POST**：与 /hotapp/export 的注册方法一致）。
  Future<NonAppExportResult> hotAppExport(String name) async {
    final handle = _clientFor(this);
    final client = handle.client;
    try {
      final res = await client
          .post(
            Uri.parse('$baseUrl/hotapp/export'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'name': name}),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        return (bytes: null, filename: null, error: _detailOf(res.body) ?? 'export_http_${res.statusCode}');
      }
      return (
        bytes: res.bodyBytes,
        filename: _filenameFrom(res.headers['content-disposition']) ?? '$name.nonapp',
        error: null,
      );
    } catch (e) {
      return (bytes: null, filename: null, error: '$e');
    } finally {
      if (handle.owned) client.close();
    }
  }

  /// 原始 zip 字节 → 服务端安装（hotapps + 作品集登记）。
  ///
  /// 失败不抛（与 api.dart 的 postJson 语义一致）：返回 `{ok:false, detail}`，
  /// UI 直接把 detail 作为稳定 code 展示。
  Future<Map<String, dynamic>> hotAppImport(List<int> bytes, {String? name}) async {
    final handle = _clientFor(this);
    final client = handle.client;
    try {
      final query = (name == null || name.isEmpty)
          ? ''
          : '?name=${Uri.encodeQueryComponent(name)}';
      final res = await client
          .post(
            Uri.parse('$baseUrl/hotapp/import$query'),
            headers: {'content-type': 'application/zip'},
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      final decoded = _decode(res.body);
      if (decoded != null) return decoded;
      return {'ok': false, 'detail': 'import_http_${res.statusCode}: ${_detailOf(res.body) ?? ''}'};
    } catch (e) {
      return {'ok': false, 'detail': 'import_failed: $e'};
    } finally {
      if (handle.owned) client.close();
    }
  }

  Future<Map<String, dynamic>> hotAppInfo(String name) =>
      getJson('/hotapp/info/${Uri.encodeQueryComponent(name)}');

  Future<Map<String, dynamic>> hotAppA2ui(String name) =>
      getJson('/hotapp/a2ui/${Uri.encodeQueryComponent(name)}');
}

Map<String, dynamic>? _decode(String body) {
  try {
    final value = jsonDecode(body);
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
  } catch (_) {}
  return null;
}

String? _detailOf(String body) {
  final decoded = _decode(body);
  final detail = decoded?['detail'] ?? decoded?['error'];
  return detail == null ? null : '$detail';
}

/// `Content-Disposition: attachment; filename="demo.nonapp"` → `demo.nonapp`。
String? _filenameFrom(String? header) {
  if (header == null) return null;
  final m = RegExp(r'''filename\s*=\s*"?([^";]+)"?''', caseSensitive: false).firstMatch(header);
  return m?.group(1)?.trim();
}
