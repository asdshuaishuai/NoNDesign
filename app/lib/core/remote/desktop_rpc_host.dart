/// The optional "连接桌面" desktop host (batch 10).
///
/// This is a `dart:io` `HttpServer` living inside the desktop app. It has no
/// Python dependency, no fixed port and no port file:
///
///  * **off by default** — constructing [DesktopRpcHost] opens no socket; the
///    user turns it on in 设置 → 智能体 → 运行方式 →「手机连接这台电脑」;
///  * **loopback by default** — with the switch on, it binds
///    `127.0.0.1:0` (ephemeral port). Only the explicit "允许手机连接" toggle
///    binds `0.0.0.0:0`, and the settings card then shows every LAN address
///    plus a warning;
///  * **token always required** — every request needs
///    `authorization: Bearer <token>`. There is no unauthenticated mode;
///  * **bounded** — 16 MiB bodies, 8 concurrent requests, 600 s stream idle
///    timeout, every failure answered with a code + a human sentence.
///
/// The wire contract lives in [rpc_protocol.dart]; the method table (which
/// delegates to the local engine, project library, 3D/hot-app/video
/// workspaces, the built-in agent and external agents) lives in
/// [rpc_methods.dart].
///
/// Lifecycle used by the shell (batch 12) and the settings card (batch 11):
///
/// ```dart
/// final host = DesktopRpcHost(services: rpcServices);
/// await host.start();                     // loopback, token generated
/// host.status.baseUrl;                    // http://127.0.0.1:54321
/// host.status.token;                      // shown to the user, once per start
/// await host.start(allowLan: true);       // restart on 0.0.0.0 + LAN warning
/// host.regenerateToken();                 // old token stops working at once
/// await host.stop();                      // listener closed, runs cancelled
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'rpc_auth.dart';
import 'rpc_methods.dart';
import 'rpc_protocol.dart';

/// Tunables. Defaults are the production contract; tests narrow the limits so
/// the behavior can be exercised without 16 MiB fixtures.
class RpcHostOptions {
  const RpcHostOptions({
    this.allowLan = false,
    this.port = 0,
    this.maxBodyBytes = RpcLimits.maxBodyBytes,
    this.maxConcurrentRequests = RpcLimits.maxConcurrentRequests,
    this.streamIdleTimeout = RpcLimits.streamIdleTimeout,
    this.keepAliveInterval = RpcLimits.keepAliveInterval,
    this.bindAddress,
  });

  /// Bind every IPv4 interface instead of loopback. Only the explicit switch
  /// may set this.
  final bool allowLan;

  /// Bind port; 0 means "let the OS choose" (the production default).
  final int port;

  final int maxBodyBytes;
  final int maxConcurrentRequests;
  final Duration streamIdleTimeout;

  /// How often a streaming reply writes an SSE comment so a dead peer is
  /// noticed by the next write. The comment never resets the idle budget.
  final Duration keepAliveInterval;

  /// Test override for the bind address; null = derived from [allowLan].
  final InternetAddress? bindAddress;

  RpcHostOptions copyWith({
    bool? allowLan,
    int? port,
    int? maxBodyBytes,
    int? maxConcurrentRequests,
    Duration? streamIdleTimeout,
    Duration? keepAliveInterval,
    InternetAddress? bindAddress,
  }) => RpcHostOptions(
    allowLan: allowLan ?? this.allowLan,
    port: port ?? this.port,
    maxBodyBytes: maxBodyBytes ?? this.maxBodyBytes,
    maxConcurrentRequests: maxConcurrentRequests ?? this.maxConcurrentRequests,
    streamIdleTimeout: streamIdleTimeout ?? this.streamIdleTimeout,
    keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
    bindAddress: bindAddress ?? this.bindAddress,
  );
}

/// Immutable snapshot of the host for the settings card and the status bar.
class RpcHostStatus {
  const RpcHostStatus({
    required this.running,
    required this.lanEnabled,
    required this.token,
    this.address = '',
    this.port = 0,
    this.lanAddresses = const [],
    this.startedAt,
    this.error,
  });

  final bool running;
  final bool lanEnabled;

  /// The live pairing token ('' only when the host never started).
  final String token;

  /// Bound address as the user should type it (`127.0.0.1` or the LAN IP).
  final String address;
  final int port;

  /// Every non-loopback IPv4 address of this machine (LAN mode only).
  final List<String> lanAddresses;

  final DateTime? startedAt;

  /// Diagnostic text when [start] failed. Never shown without "技术详情".
  final String? error;

  /// `http://<address>:<port>` or '' when not running.
  String get baseUrl => running && port > 0 ? 'http://$address:$port' : '';

  /// URLs a phone can paste, one per LAN address (empty in loopback mode).
  List<String> get lanUrls => <String>[
    for (final host in lanAddresses) 'http://$host:$port',
  ];

  bool get loopbackOnly => !lanEnabled;

  /// Warning the settings card must show while LAN mode is on.
  String get warning => lanEnabled ? '手机连接已开启，请只在信任的网络里使用' : '';

  @override
  String toString() =>
      'RpcHostStatus(running:$running, lan:$lanEnabled, $baseUrl, token:${token.isEmpty ? 'none' : 'set'})';
}

/// One desktop RPC host. Owns the server, the token and the method table.
class DesktopRpcHost {
  DesktopRpcHost({
    required this.services,
    RpcHostOptions options = const RpcHostOptions(),
    RpcAuthToken? token,
    // ignore: prefer_initializing_formals
  }) : _options = options,
       _token = token ?? RpcAuthToken.generate(),
       table = RpcMethodTable(services);

  /// Services the methods delegate to (engine, projects, workspaces, agent).
  final RpcServices services;

  /// Method table; exposed for tests and for `capabilities` inspection.
  final RpcMethodTable table;

  final RpcHostOptions _options;
  RpcAuthToken _token;
  HttpServer? _server;
  DateTime? _startedAt;
  List<String> _lanAddresses = const <String>[];
  String? _error;
  int _activeRequests = 0;
  bool _disposed = false;

  /// Current status snapshot (safe to call at any time).
  ///
  /// [RpcHostStatus.token] is the live pairing token: it is regenerated on
  /// every successful [(re)start] and by [regenerateToken]. Show it to the
  /// user (the phone types it); never log it.
  RpcHostStatus get status => RpcHostStatus(
    running: _server != null,
    lanEnabled: _lanEnabled,
    token: _token.value,
    address: _server?.address.address ?? '',
    port: _server?.port ?? 0,
    lanAddresses: _lanAddresses,
    startedAt: _startedAt,
    error: _error,
  );

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  bool _lanEnabled = false;

  /// Starts listening.
  ///
  /// [allowLan] may be passed to flip the loopback/LAN switch; omitting it
  /// keeps the configured default. Calling [start] while running with the same
  /// mode is a no-op. Returns the resulting [RpcHostStatus] — a bind failure
  /// is reported there, never thrown.
  Future<RpcHostStatus> start({bool? allowLan}) async {
    if (_disposed) return status;
    final lan = allowLan ?? _options.allowLan;
    if (_server != null && lan == _lanEnabled) return status;
    if (_server != null) await stop();

    _lanEnabled = lan;
    _error = null;
    // Every start pairs afresh: the token is regenerated before the listener
    // opens, so a token leaked before a restart or a loopback→LAN switch is
    // dead the moment the new listener is up.
    _token = RpcAuthToken.generate();
    final address =
        _options.bindAddress ??
        (lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4);
    try {
      final server = await HttpServer.bind(address, _options.port);
      server.autoCompress = false; // SSE must not be buffered by gzip
      server.idleTimeout = RpcLimits.connectionIdleTimeout;
      _server = server;
      _startedAt = DateTime.now();
      _lanAddresses = lan ? await _localAddresses() : const <String>[];
      server.listen(_handle, onError: (Object error) {
        _error = '$error';
      }, cancelOnError: false);
      return status;
    } catch (error) {
      _server = null;
      _startedAt = null;
      _lanAddresses = const <String>[];
      _error = '$error';
      return status;
    }
  }

  /// Stops listening immediately and cancels any in-flight run.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _startedAt = null;
    _lanAddresses = const <String>[];
    _activeRequests = 0;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {
        // Already closed / socket reset: nothing left to do.
      }
    }
    await table.shutdown();
  }

  /// Rotates the pairing token. In-flight requests finish with the token they
  /// presented; the next request must use the new one.
  RpcAuthToken regenerateToken() {
    _token = RpcAuthToken.generate();
    return _token;
  }

  /// Releases the host (equivalent to [stop], but idempotent forever).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }

  // -------------------------------------------------------------------------
  // HTTP handling
  // -------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final probe = request.method == 'GET' && (path == '/v1/health' || path == '/v1/capabilities');
    var counted = false;
    try {
      if (!_authorized(request)) {
        await _json(
          request,
          401,
          rpcFailure(RpcErrorCode.unauthorized, message: RpcCopy.unauthorized, includeMessage: true),
          close: true,
        );
        return;
      }
      if (!probe) {
        if (_activeRequests >= _options.maxConcurrentRequests) {
          await _json(
            request,
            503,
            rpcFailure(RpcErrorCode.busy, message: RpcCopy.busy, includeMessage: true),
            close: true,
          );
          return;
        }
        _activeRequests += 1;
        counted = true;
      }

      if (request.method == 'GET') {
        if (path == '/v1/health') {
          final payload = <String, dynamic>{
            ...table.healthPayload(),
            'uptime_s': _startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inSeconds,
            'loopback': !_lanEnabled,
          };
          await _json(request, 200, payload);
          return;
        }
        if (path == '/v1/capabilities') {
          await _json(request, 200, table.capabilitiesPayload());
          return;
        }
        if (path == '/v1/rpc') {
          await _json(
            request,
            405,
            rpcFailure(RpcErrorCode.methodNotAllowed, message: RpcCopy.methodNotAllowed),
          );
          return;
        }
        if (path.startsWith('/v1/assets/')) {
          await _serveAsset(request);
          return;
        }
        await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
        return;
      }

      if (path == '/v1/rpc') {
        if (request.method != 'POST') {
          await _json(
            request,
            405,
            rpcFailure(RpcErrorCode.methodNotAllowed, message: RpcCopy.methodNotAllowed),
          );
          return;
        }
        await _handleRpc(request);
        return;
      }

      if (path == '/v1/health' || path == '/v1/capabilities') {
        await _json(
          request,
          405,
          rpcFailure(RpcErrorCode.methodNotAllowed, message: RpcCopy.methodNotAllowed),
        );
        return;
      }
      await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
    } catch (error) {
      // A handler that escaped its own try/catch or a socket write failure.
      try {
        await _json(
          request,
          500,
          rpcFailure(RpcErrorCode.internal, detail: '$error', message: RpcCopy.internal, includeMessage: true),
          close: true,
        );
      } catch (_) {
        // The socket is already gone; nothing can be sent.
      }
    } finally {
      if (counted) _activeRequests -= 1;
    }
  }

  bool _authorized(HttpRequest request) {
    if (_token.matches(request.headers.value(HttpHeaders.authorizationHeader))) {
      return true;
    }
    // A WebView navigation cannot set headers, so asset GETs accept the same
    // token as a query parameter. Every other face requires the header.
    if (request.method == 'GET' && request.uri.path.startsWith('/v1/assets/')) {
      final queryToken = request.uri.queryParameters['token'];
      if (queryToken != null && queryToken.isNotEmpty) {
        return _token.matches('Bearer $queryToken');
      }
    }
    return false;
  }

  Future<void> _handleRpc(HttpRequest request) async {
    final bytes = await _readBody(request);
    if (bytes == null) {
      await _json(
        request,
        413,
        rpcFailure(RpcErrorCode.payloadTooLarge, message: RpcCopy.payloadTooLarge, includeMessage: true),
        close: true,
      );
      return;
    }

    Object? decoded;
    try {
      decoded = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error) {
      await _json(
        request,
        400,
        rpcFailure(RpcErrorCode.badRequest, detail: '$error', message: RpcCopy.badRequest),
      );
      return;
    }

    final parsed = RpcRequest.parse(decoded);
    final rpc = parsed.request;
    if (rpc == null) {
      await _json(
        request,
        400,
        rpcFailure(parsed.error ?? RpcErrorCode.badRequest, detail: parsed.detail, message: RpcCopy.badRequest),
      );
      return;
    }

    if (!rpcProtocolSupported(rpc.protocol)) {
      await _json(
        request,
        200,
        rpcOk(
          rpcFailure(
            RpcErrorCode.unsupportedProtocol,
            detail: 'host protocol $rpcProtocolVersion, client ${rpc.protocol}',
            message: RpcCopy.unsupportedProtocol,
            includeMessage: true,
          ),
        ),
      );
      return;
    }

    if (table.isStreaming(rpc.method)) {
      final handle = table.openStream(rpc.method, rpc.params);
      if (handle == null) {
        await _json(
          request,
          200,
          rpcOk(rpcFailure(RpcErrorCode.unknownMethod, detail: rpc.method, message: RpcCopy.unknownMethod)),
        );
        return;
      }
      await _writeStream(request, handle);
      return;
    }

    final result = await table.invoke(rpc.method, rpc.params);
    await _json(request, 200, rpcOk(result));
  }

  /// Reads the body up to [RpcHostOptions.maxBodyBytes]. Returns null when the
  /// limit is crossed (the caller answers 413 and drops the connection).
  Future<List<int>?> _readBody(HttpRequest request) async {
    final limit = _options.maxBodyBytes;
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in request) {
        builder.add(chunk);
        if (builder.length > limit) return null;
      }
    } catch (_) {
      // Client aborted mid-body: treat as an empty/invalid request.
      return const <int>[];
    }
    return builder.takeBytes();
  }

  /// Writes one streaming reply as SSE, enforcing the idle budget.
  ///
  /// Two independent guards keep a dead phone from leaving a run burning
  /// tokens:
  ///
  ///  * an SSE comment is written every [RpcHostOptions.keepAliveInterval].
  ///    `dart:io` does not surface a peer reset as an exception — a write to a
  ///    dead socket can hang instead — so each flush has a
  ///    `2 × keepAliveInterval` deadline; a miss means the peer is gone and
  ///    the run is cancelled;
  ///  * the event source is cut after [RpcHostOptions.streamIdleTimeout] of
  ///    silence with a terminal `failed` event.
  ///
  /// The comment does **not** touch the idle budget — it only proves the
  /// socket still exists.
  Future<void> _writeStream(HttpRequest request, RpcStreamHandle handle) async {
    final response = request.response;
    response.statusCode = 200;
    response.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('x-accel-buffering', 'no');
    response.bufferOutput = false;

    var terminal = false;
    var clientGone = false;
    final gone = Completer<void>();

    // All writes go through one chain: the event loop and the keep-alive timer
    // must never interleave a partial frame.
    Future<void> writeChain = Future<void>.value();
    Future<void> enqueue(String text) {
      writeChain = writeChain.then((_) async {
        if (clientGone) return;
        response.write(text);
        await response.flush().timeout(_options.keepAliveInterval * 2);
      }).catchError((Object _) {
        if (!clientGone) {
          clientGone = true;
          if (!gone.isCompleted) gone.complete();
        }
      });
      return writeChain;
    }

    final keepAlive = Timer.periodic(_options.keepAliveInterval, (_) {
      unawaited(enqueue(': ping\n\n'));
    });

    final iterator = StreamIterator<Map<String, dynamic>>(
      handle.events.timeout(_options.streamIdleTimeout),
    );

    Future<void> writeTerminal(String code) => enqueue(
      encodeSseEvent(<String, dynamic>{
        'type': 'failed',
        'error': code,
        'message': RpcCopy.streamIdle,
        'stopReason': 'failed',
      }),
    );

    try {
      while (!clientGone) {
        // `moveNext` keeps waiting while the run thinks; `gone` fires when a
        // keep-alive write proves the peer vanished. First completion wins.
        final hasNext = await Future.any<bool>(<Future<bool>>[
          iterator.moveNext(),
          gone.future.then((_) => false),
        ]);
        if (!hasNext) {
          if (!clientGone) {
            // The source ended without a terminal event: close the contract
            // ourselves so the client's busy state can never hang.
            await writeTerminal(RpcErrorCode.streamIdle);
          }
          break;
        }
        final event = iterator.current;
        await enqueue(encodeSseEvent(event));
        if (isTerminalEvent(event)) {
          terminal = true;
          break;
        }
      }
    } on TimeoutException {
      if (!clientGone) await writeTerminal(RpcErrorCode.streamIdle);
    } catch (_) {
      // Client disconnected mid-write: the finally block cancels the work.
    } finally {
      keepAlive.cancel();
      await iterator.cancel();
      if (!terminal) handle.onClientGone?.call();
      try {
        await writeChain;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {
        // Ignore: the peer may have reset the connection.
      }
    }
  }

  /// Serves a self-contained preview page for 3D scenes and hot apps.
  ///
  /// A WebView navigation cannot carry an Authorization header, so the token
  /// may travel in `?token=`. Pages are served with a strict CSP: no external
  /// network, no framing, inline script/style only (the preview HTML inlines
  /// both by construction).
  Future<void> _serveAsset(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    // ['v1', 'assets', '<kind>', '<name>']
    if (segments.length != 4) {
      await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
      return;
    }
    final kind = segments[2];
    final name = segments[3];
    if (name.isEmpty) {
      await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
      return;
    }

    try {
      if (kind == 'three') {
        final service = await services.three();
        final bundle = await service.preparePreview(name);
        final file = File(bundle.htmlPath);
        if (!await file.exists()) {
          await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
          return;
        }
        await _writeHtml(request, await file.readAsBytes());
        return;
      }
      if (kind == 'hotapp') {
        final service = await services.hotApp();
        final html = await service.html(name);
        if (html != null) {
          await _writeHtml(request, utf8.encode(html));
          return;
        }
        final surface = await service.surface(name);
        if (surface != null) {
          await _json(request, 200, <String, dynamic>{'ok': true, 'surface': surface});
          return;
        }
        await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
        return;
      }
      await _json(request, 404, rpcFailure(RpcErrorCode.notFound, message: RpcCopy.notFound));
    } catch (error) {
      await _json(request, 404, rpcFailure(RpcErrorCode.notFound, detail: '$error', message: RpcCopy.notFound));
    }
  }

  static const String _assetCsp =
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
      "img-src data: blob:; font-src data:; media-src data: blob:; "
      "connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

  Future<void> _writeHtml(HttpRequest request, List<int> bytes) async {
    final response = request.response;
    response.statusCode = 200;
    response.headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('content-security-policy', _assetCsp);
    response.headers.set('x-content-type-options', 'nosniff');
    response.add(bytes);
    await response.close();
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> payload, {
    bool close = false,
  }) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('x-content-type-options', 'nosniff');
    if (close) response.headers.set(HttpHeaders.connectionHeader, 'close');
    response.write(jsonEncode(payload));
    await response.close();
  }

  Future<List<String>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback && !addresses.contains(address.address)) {
            addresses.add(address.address);
          }
        }
      }
      return addresses;
    } catch (_) {
      return const <String>[];
    }
  }
}
