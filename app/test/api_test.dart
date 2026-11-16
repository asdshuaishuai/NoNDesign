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
}
