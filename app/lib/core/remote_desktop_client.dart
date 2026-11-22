/// Optional "连接桌面" runtime: a desktop host that answers a small JSON-RPC
/// contract over loopback / LAN.
///
/// Contract (the desktop host lands in batch 10; this file is the client):
///
///   GET  /v1/health        → {ok, version, name, capabilities?}
///   GET  /v1/capabilities  → {ok, version, capabilities:{engine, agent, ...}}
///   POST /v1/rpc           → {ok, result:{…}} | {ok:false, error, detail}
///        body: {method: "engine.render", params:{…}}
///   POST /v1/rpc (SSE)     → method `agent.run`, `accept: text/event-stream`;
///                            one JSON event per `data:` line, terminal
///                            `done` / `failed`. Plain JSON bodies and JSONL
///                            are accepted too (a host may not stream at all).
///
/// Rules that keep this honest:
///
///  * a missing or unreachable desktop is **never** papered over: every call
///    returns `{ok:false, error:'remote_…'}` so the caller can show the real
///    reason instead of silently pretending the work happened;
///  * the user-facing sentence ([RemoteDesktopStatus.message]) follows
///    `docs/copy-glossary.md`; host names, ports and tokens only ever appear in
///    `technicalDetail`, which the UI keeps behind a collapsed disclosure;
///  * no fixed port, no port file, no process spawning: connecting is an
///    explicit user decision (`serverUrl` + optional one-time token).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Stable error codes produced by this client (diagnostics only — user copy is
/// derived by the caller and must never print these).
abstract final class RemoteErrorCode {
  /// No route to the desktop at all (wrong address, host off, network).
  static const String unreachable = 'remote_unreachable';

  /// The desktop answered but rejected the token.
  static const String unauthorized = 'remote_unauthorized';

  /// The desktop is too old / does not expose the RPC contract.
  static const String unsupported = 'remote_unsupported';

  /// The desktop answered, but not within the client budget.
  static const String timeout = 'remote_timeout';

  /// Answer was not a JSON object in the contract shape.
  static const String badResponse = 'remote_bad_response';

  /// Streaming stopped producing events for longer than [sseIdleTimeout].
  static const String streamIdle = 'sse_idle_timeout';
}

/// Result of a connection probe (health + capabilities).
///
/// [message] is the only sentence a surface may show directly; [reason] and
/// [technicalDetail] belong in "技术详情".
class RemoteDesktopStatus {
  /// Whether a desktop address is configured at all.
  final bool configured;

  /// Whether the health face answered.
  final bool reachable;

  /// Whether the token (when one is configured) was accepted.
  final bool authorized;

  /// Whether the host speaks the RPC contract used by this client.
  final bool compatible;

  /// Host-reported version (diagnostics only).
  final String? version;

  /// Host-reported capability map (`{engine:true, agent:true, …}`).
  final Map<String, dynamic> capabilities;

  /// Internal error code, if the probe failed.
  final String? reason;

  /// Raw diagnostic text (host error, HTTP status). Never shown directly.
  final String? technicalDetail;

  /// User-facing sentence for this snapshot.
  final String message;

  const RemoteDesktopStatus({
    required this.configured,
    required this.reachable,
    required this.authorized,
    required this.compatible,
    required this.message,
    this.version,
    this.capabilities = const {},
    this.reason,
    this.technicalDetail,
  });

  /// Not configured at all — "还没有连接桌面".
  const RemoteDesktopStatus.notConfigured()
      : configured = false,
        reachable = false,
        authorized = false,
        compatible = false,
        version = null,
        capabilities = const {},
        reason = null,
        technicalDetail = null,
        message = '还没有连接桌面';

  /// True only when the desktop can actually be used right now.
  bool get connected => configured && reachable && authorized && compatible;

  /// Whether the host advertises [capability] (engine / agent / three …).
  bool supports(String capability) => capabilities[capability] == true;

  @override
  String toString() =>
      'RemoteDesktopStatus(configured:$configured, reachable:$reachable, '
      'authorized:$authorized, compatible:$compatible)';
}

/// JSON-RPC client for the optional desktop runtime.
class RemoteDesktopClient {
  RemoteDesktopClient({
    required String baseUrl,
    String token = '',
    http.Client? client,
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        token = token.trim(),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Normalises a user-typed address: whitespace trimmed, scheme added when
  /// missing, trailing slashes removed. Returns '' for an empty input.
  static String normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    value = value.replaceAll(RegExp(r'/+$'), '');
    if (!value.contains('://')) value = 'http://$value';
    return value;
  }

  /// Address of the connected desktop ('' when not configured).
  final String baseUrl;

  /// One-time pairing token. The host requires it on every `/v1` request
  /// (including health), so an empty value always fails with 401.
  final String token;

  final http.Client _client;
  final bool _ownsClient;

  /// Health probe budget (one attempt).
  static Duration probeTimeout = const Duration(seconds: 3);

  /// Ordinary RPC budget.
  static Duration rpcTimeout = const Duration(seconds: 30);

  /// Long-running generative RPCs (3D spec, hot-app generation).
  static Duration llmGenTimeout = const Duration(minutes: 10);

  /// Idle budget between two streamed agent events.
  static Duration sseIdleTimeout = const Duration(seconds: 660);

  bool get isConfigured => baseUrl.isNotEmpty;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'accept': 'application/json',
        if (token.isNotEmpty) 'authorization': 'Bearer $token',
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, dynamic> _error(String code, [Object? detail]) => <String, dynamic>{
        'ok': false,
        'error': code,
        if (detail != null) 'detail': '$detail',
      };

  /// Decodes an HTTP response into the envelope shape used by the app.
  ///
  /// Non-2xx statuses become `{ok:false, status, error, detail}` — the client
  /// never throws for a server-side failure.
  Map<String, dynamic> _decode(http.Response res) {
    dynamic value;
    if (res.body.isNotEmpty) {
      try {
        value = jsonDecode(res.body);
      } catch (_) {
        value = null; // proxy error page / plain text body
      }
    }
    final okStatus = res.statusCode >= 200 && res.statusCode < 300;
    if (!okStatus) {
      final code = switch (res.statusCode) {
        401 || 403 => RemoteErrorCode.unauthorized,
        404 || 405 => RemoteErrorCode.unsupported,
        _ => 'remote_http_${res.statusCode}',
      };
      String detail;
      if (value is Map) {
        detail = (value['detail'] ?? value['error'] ?? res.body).toString();
      } else {
        final text = res.body.trim();
        detail = text.isEmpty ? 'HTTP ${res.statusCode}' : text;
      }
      if (detail.length > 500) detail = '${detail.substring(0, 500)}…';
      return {'ok': false, 'status': res.statusCode, 'error': code, 'detail': detail};
    }
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value == null && res.body.isEmpty) return _error(RemoteErrorCode.badResponse, 'empty body');
    return _error(RemoteErrorCode.badResponse, 'status ${res.statusCode}');
  }

  // -------------------------------------------------------------------------
  // Probe
  // -------------------------------------------------------------------------

  /// Raw health face.
  Future<Map<String, dynamic>> health({Duration? timeout}) async {
    if (!isConfigured) return _error(RemoteErrorCode.unreachable, 'no address configured');
    try {
      final res = await _client
          .get(_uri('/v1/health'), headers: _headers)
          .timeout(timeout ?? probeTimeout);
      return _decode(res);
    } on TimeoutException catch (e) {
      return _error(RemoteErrorCode.timeout, '$e');
    } catch (e) {
      return _error(RemoteErrorCode.unreachable, '$e');
    }
  }

  /// Raw capabilities face.
  Future<Map<String, dynamic>> capabilities({Duration? timeout}) async {
    if (!isConfigured) return _error(RemoteErrorCode.unreachable, 'no address configured');
    try {
      final res = await _client
          .get(_uri('/v1/capabilities'), headers: _headers)
          .timeout(timeout ?? probeTimeout);
      return _decode(res);
    } on TimeoutException catch (e) {
      return _error(RemoteErrorCode.timeout, '$e');
    } catch (e) {
      return _error(RemoteErrorCode.unreachable, '$e');
    }
  }

  /// Probes the desktop and turns the outcome into user-ready copy.
  ///
  /// [attempts] > 1 retries the health face with a short backoff (useful right
  /// after the user turns the desktop host on).
  Future<RemoteDesktopStatus> probe({int attempts = 1}) async {
    if (!isConfigured) return const RemoteDesktopStatus.notConfigured();

    Map<String, dynamic> healthReply = _error(RemoteErrorCode.unreachable);
    for (var attempt = 0; attempt < attempts; attempt++) {
      healthReply = await health();
      if (healthReply['ok'] == true) break;
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }

    final version = healthReply['version']?.toString();
    if (healthReply['ok'] != true) {
      final reason = healthReply['error']?.toString() ?? RemoteErrorCode.unreachable;
      return RemoteDesktopStatus(
        configured: true,
        reachable: reason != RemoteErrorCode.unreachable && reason != RemoteErrorCode.timeout,
        authorized: reason != RemoteErrorCode.unauthorized,
        compatible: false,
        version: version,
        reason: reason,
        technicalDetail: healthReply['detail']?.toString(),
        message: reason == RemoteErrorCode.unauthorized
            ? '连接码不正确，请在桌面端重新获取'
            : '连接桌面没有成功，请检查地址与桌面端是否已开启连接',
      );
    }

    final capsReply = await capabilities();
    final rawCaps = capsReply['capabilities'];
    final caps = rawCaps is Map ? Map<String, dynamic>.from(rawCaps) : <String, dynamic>{};
    // A host that answers /v1/health but not /v1/capabilities is an older
    // build: it is reachable and authorised, just not compatible with this
    // client. Do not pretend it works.
    final compatible = capsReply['ok'] == true;
    return RemoteDesktopStatus(
      configured: true,
      reachable: true,
      authorized: true,
      compatible: compatible,
      version: version ?? capsReply['version']?.toString(),
      capabilities: caps,
      reason: compatible ? null : RemoteErrorCode.unsupported,
      technicalDetail: compatible ? null : capsReply['detail']?.toString(),
      message: compatible
          ? '已连接桌面'
          : '桌面端版本过旧，请在本机更新后再连接',
    );
  }

  // -------------------------------------------------------------------------
  // RPC
  // -------------------------------------------------------------------------

  /// One JSON-RPC call. Never throws: transport failures become envelopes.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
    Duration? timeout,
  ]) async {
    if (!isConfigured) return _error(RemoteErrorCode.unreachable, 'no address configured');
    try {
      final res = await _client
          .post(
            _uri('/v1/rpc'),
            headers: _headers,
            body: jsonEncode({'method': method, 'params': params ?? const <String, dynamic>{}}),
          )
          .timeout(timeout ?? rpcTimeout);
      final decoded = _decode(res);
      if (decoded['ok'] != true) return decoded;
      final result = decoded['result'];
      if (result is Map) {
        final out = Map<String, dynamic>.from(result);
        out.putIfAbsent('ok', () => true);
        return out;
      }
      if (result is List) return {'ok': true, 'data': result};
      return decoded;
    } on TimeoutException catch (e) {
      return _error(RemoteErrorCode.timeout, '$e');
    } catch (e) {
      return _error(RemoteErrorCode.unreachable, '$e');
    }
  }

  /// Streaming agent run (`agent.run`).
  Stream<Map<String, dynamic>> agentRun(Map<String, dynamic> body) =>
      streamCall('agent.run', body);

  /// Generic streaming RPC (agent runs and external-agent prompts).
  ///
  /// Yields the same event shapes the built-in loop produces (`note`,
  /// `tool_start`, `tool_end`, `assistant_delta`, `doc_delta`, `done`,
  /// `failed`, …) and always ends with a terminal event: a stalled stream
  /// synthesises `{type:'failed', error:'sse_idle_timeout'}` so the caller's
  /// busy state can never hang forever.
  Stream<Map<String, dynamic>> streamCall(
    String method,
    Map<String, dynamic> params,
  ) async* {
    if (!isConfigured) {
      yield {
        'type': 'failed',
        'error': RemoteErrorCode.unreachable,
        'detail': 'no address configured',
        'stopReason': 'failed',
      };
      return;
    }
    final request = http.Request('POST', _uri('/v1/rpc'))
      ..headers.addAll({..._headers, 'accept': 'text/event-stream'})
      ..body = jsonEncode({'method': method, 'params': params});

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 30));
    } on TimeoutException catch (e) {
      yield {'type': 'failed', 'error': RemoteErrorCode.timeout, 'detail': '$e', 'stopReason': 'failed'};
      return;
    } catch (e) {
      yield {
        'type': 'failed',
        'error': RemoteErrorCode.unreachable,
        'detail': '$e',
        'stopReason': 'failed',
      };
      return;
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      yield {
        'type': 'failed',
        'error': RemoteErrorCode.unauthorized,
        'detail': 'HTTP ${response.statusCode}',
        'stopReason': 'failed',
      };
      return;
    }
    if (response.statusCode != 200) {
      yield {
        'type': 'failed',
        'error': 'remote_http_${response.statusCode}',
        'detail': 'HTTP ${response.statusCode}',
        'stopReason': 'failed',
      };
      return;
    }

    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.contains('event-stream')) {
      // A host may answer with one JSON document instead of a stream (older
      // build or a proxy that buffers). Accept both shapes rather than
      // declaring failure on a perfectly good run.
      String text;
      try {
        text = await response.stream.bytesToString().timeout(sseIdleTimeout);
      } catch (e) {
        yield {'type': 'failed', 'error': RemoteErrorCode.streamIdle, 'detail': '$e', 'stopReason': 'failed'};
        return;
      }
      final events = _eventsFromBody(text);
      if (events.isEmpty) {
        yield {
          'type': 'failed',
          'error': RemoteErrorCode.badResponse,
          'detail': 'unrecognised body',
          'stopReason': 'failed',
        };
        return;
      }
      for (final event in events) {
        yield event;
        if (_isTerminal(event)) return;
      }
      return;
    }

    var stalled = false;
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(sseIdleTimeout, onTimeout: (sink) {
      stalled = true;
      sink.close();
    });
    await for (final line in lines) {
      final event = _eventFromLine(line);
      if (event == null) continue;
      yield event;
      if (_isTerminal(event)) return;
    }
    if (stalled) {
      yield {'type': 'failed', 'error': RemoteErrorCode.streamIdle, 'stopReason': 'failed'};
    }
  }

  /// Cancels the in-flight agent run on the host (best effort).
  Future<Map<String, dynamic>> cancelAgent(int runId) =>
      call('agent.cancel', {'run_id': runId}, const Duration(seconds: 10));

  static bool _isTerminal(Map<String, dynamic> event) =>
      event['type'] == 'done' || event['type'] == 'failed';

  /// One wire line → event. Supports SSE (`data: {...}`) and JSONL (`{...}`).
  static Map<String, dynamic>? _eventFromLine(String rawLine) {
    var line = rawLine.trim();
    if (line.isEmpty) return null;
    if (line.startsWith('data:')) {
      line = line.substring(5).trim();
      if (line.isEmpty) return null;
    } else if (line.startsWith(':') || line.startsWith('event:') || line.startsWith('id:')) {
      return null; // SSE framing noise
    }
    try {
      final value = jsonDecode(line);
      if (value is Map<String, dynamic>) return value;
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {
      // Not a JSON line (keep-alive text, partial chunk): ignore.
    }
    return null;
  }

  /// Whole-body fallback → event list.
  static List<Map<String, dynamic>> _eventsFromBody(String text) {
    final events = <Map<String, dynamic>>[];
    final trimmed = text.trim();
    if (trimmed.isEmpty) return events;
    try {
      final value = jsonDecode(trimmed);
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        // `{ok,result:{…event…}}` or a bare event object.
        final result = map['result'];
        if (result is Map) return [Map<String, dynamic>.from(result)];
        if (map['events'] is List) {
          for (final raw in map['events'] as List) {
            if (raw is Map) events.add(Map<String, dynamic>.from(raw));
          }
          return events;
        }
        return [map];
      }
      if (value is List) {
        for (final raw in value) {
          if (raw is Map) events.add(Map<String, dynamic>.from(raw));
        }
        return events;
      }
    } catch (_) {
      // Fall through to JSONL parsing.
    }
    for (final line in const LineSplitter().convert(trimmed)) {
      final event = _eventFromLine(line);
      if (event != null) events.add(event);
    }
    return events;
  }

  /// Releases the HTTP client when this instance owns it.
  void close() {
    if (_ownsClient) _client.close();
  }
}
