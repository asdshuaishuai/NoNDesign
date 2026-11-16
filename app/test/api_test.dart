import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';

void main() {
  test('agentRun parses SSE events and stops at done', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'note', 'label': 'start'})}\n\n');
      request.response.write('data: ${jsonEncode({'type': 'assistant_delta', 'text': 'hi'})}\n\n');
      request.response.write('data: ${jsonEncode({'type': 'done', 'text': 'ok', 'stopReason': 'done'})}\n\n');
      await request.response.close();
    });
    final api = NoNDesignApi('http://127.0.0.1:${server.port}');
    final events = await api
        .agentRun({'run_id': 1, 'mode': 'build', 'instruction': 'x'})
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events.map((e) => e['type']), ['note', 'assistant_delta', 'done']);
    expect(events.last['text'], 'ok');
    await server.close(force: true);
  });

  test('non-2xx responses surface status/detail instead of throwing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/plain') {
        request.response.statusCode = 500;
        request.response.write('boom');
      } else {
        request.response.statusCode = 502;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'detail': 'upstream down'}));
      }
      await request.response.close();
    });
    final api = NoNDesignApi('http://127.0.0.1:${server.port}');
    final plain = await api.getJson('/plain');
    expect(plain['ok'], false);
    expect(plain['status'], 500);
    expect(plain['detail'], 'boom');
    final jsonRes = await api.getJson('/json');
    expect(jsonRes['ok'], false);
    expect(jsonRes['status'], 502);
    expect(jsonRes['detail'], 'upstream down');
    await server.close(force: true);
  });

  // ---- 2026-11-17 核心状态机批次回归锚 ----

  test('manual server url trailing slash is stripped from the handle baseUrl', () async {
    // 移动端「连接桌面」地址带单个尾斜杠：_healthy 自行剥斜杠所以健康检查
    // 能过，但 handle.baseUrl 保留斜杠会让之后所有路径变成 //path 而 404
    // （启动死锁在误导性 no models in registry）。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true}));
      await request.response.close();
    });
    ServerLauncher.manualBaseUrl = 'http://127.0.0.1:${server.port}/';
    addTearDown(() => ServerLauncher.manualBaseUrl = null);

    final handle = await ServerLauncher.launch();

    expect(handle.baseUrl, 'http://127.0.0.1:${server.port}');
    final api = NoNDesignApi(handle.baseUrl);
    final models = await api.models();
    expect(models['ok'], true);
    expect(paths, containsAllInOrder(['/health', '/models']),
        reason: '路径必须是 /models 而非 //models');
    await server.close(force: true);
  });

  test('agentRun synthesizes a failed terminal when the stream stalls mid-flight', () async {
    // 流中空闲超时：服务端进程活、响应头已回但不再发数据——此前 await for
    // 永挂。现在收流并合成 sse_idle_timeout 终态（SSE 必须始终有终态事件）。
    // 本机 dart:io 的 HttpResponse.flush() 只推响应头、body 压到 close 才
    // 到（探针实证）——这里稳定呈现为「连接后静默」的空闲；「事件到达后再
    // 卡死」由 store_test 的原始 socket mock 覆盖。
    NoNDesignApi.sseIdleTimeout = const Duration(milliseconds: 250);
    addTearDown(() => NoNDesignApi.sseIdleTimeout = const Duration(seconds: 660));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'note', 'label': 'start'})}\n\n');
      await request.response.flush(); // 头已上网络、行未到——之后永久卡死
      await Completer<void>().future;
    });
    final api = NoNDesignApi('http://127.0.0.1:${server.port}');
    final events = await api
        .agentRun({'run_id': 1, 'mode': 'build', 'instruction': 'x'})
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events.map((e) => e['type']), ['failed']);
    expect(events.last['error'], 'sse_idle_timeout');
    await server.close(force: true);
  });

  test('acpPrompt also synthesizes a failed terminal on stream stall', () async {
    NoNDesignApi.sseIdleTimeout = const Duration(milliseconds: 250);
    addTearDown(() => NoNDesignApi.sseIdleTimeout = const Duration(seconds: 660));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'assistant_delta', 'text': 'hi'})}\n\n');
      await request.response.flush();
      await Completer<void>().future;
    });
    final api = NoNDesignApi('http://127.0.0.1:${server.port}');
    final events = await api
        .acpPrompt('sid', 'hello')
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events.map((e) => e['type']), ['failed']);
    expect(events.last['error'], 'sse_idle_timeout');
    await server.close(force: true);
  });
}
