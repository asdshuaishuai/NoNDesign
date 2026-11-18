/// Pairing token for the optional "连接桌面" host (batch 10).
///
/// Security model:
///
///  * the token is **always required** — there is no unauthenticated mode,
///    not even on loopback. The previous Python service accepted any request
///    on the LAN; that is exactly what this replaces;
///  * it is generated with [Random.secure] on every start and on demand
///    ("重新生成"), so a leaked token stops working after the next restart
///    or regeneration;
///  * the desktop shows it verbatim in the settings card (the phone has to be
///    able to type it), and [RpcAuthToken.hint] gives a short form for logs
///    and status rows;
///  * comparison is constant-time over UTF-8 bytes to keep timing from
///    distinguishing "wrong prefix" from "wrong byte 30".
///
/// Format: 24 random bytes, base64url without padding → 32 characters drawn
/// from `A–Z a–z 0–9 - _`, which is typeable on a phone keyboard.
library;

import 'dart:convert';
import 'dart:math';

/// One immutable pairing token.
class RpcAuthToken {
  RpcAuthToken._(this.value);

  /// Wraps an explicitly provided value (tests, or a token restored by the
  /// host across an in-process restart). Empty values are rejected by [isValid].
  factory RpcAuthToken(String value) => RpcAuthToken._(value.trim());

  /// Generates a fresh token. [random] is injectable for deterministic tests.
  factory RpcAuthToken.generate({Random? random}) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(24, (_) => source.nextInt(256));
    final encoded = base64UrlEncode(bytes).replaceAll('=', '');
    return RpcAuthToken._(encoded);
  }

  /// Raw token as shown to the user.
  final String value;

  /// A token with at least 16 characters is considered usable. Anything
  /// shorter is treated as "not configured" rather than silently accepted.
  bool get isValid => value.length >= 16;

  /// Short form for status rows and logs (`abcd…wxyz`). Never use it for auth.
  String get hint {
    if (value.length <= 10) return value;
    return '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
  }

  /// Length of the fixed prefix used by the constant-time comparison.
  static const int _prefixBytes = 32;

  /// Whether the request carries this token.
  ///
  /// Accepts `Bearer <token>` (the client contract) and a bare `<token>`
  /// (handy for `curl`). The scheme is case-insensitive per RFC 7235.
  bool matches(String? authorizationHeader) {
    final presented = extract(authorizationHeader);
    if (presented == null) return false;
    return _constantTimeEquals(value, presented);
  }

  /// Pulls the credential out of an `Authorization` header value.
  ///
  /// Returns null for absent/empty headers. A value that looks like
  /// `<scheme> <credential>` is split on the first space only.
  static String? extract(String? header) {
    if (header == null) return null;
    final trimmed = header.trim();
    if (trimmed.isEmpty) return null;
    final space = trimmed.indexOf(' ');
    if (space <= 0) return trimmed;
    final scheme = trimmed.substring(0, space).toLowerCase();
    final credential = trimmed.substring(space + 1).trim();
    if (scheme != 'bearer' && scheme != 'token') return null;
    return credential.isEmpty ? null : credential;
  }

  @override
  String toString() => 'RpcAuthToken($hint)';
}

/// Compares two strings without an early exit on the first differing byte.
///
/// Length is compared first (a length mismatch is observable anyway, since
/// HTTP framing reveals it); the bytes then run through a fixed-width loop
/// over a 32-byte window so the common case does not leak position.
bool _constantTimeEquals(String expected, String presented) {
  final a = utf8.encode(expected);
  final b = utf8.encode(presented);
  if (a.length != b.length) return false;
  var diff = 0;
  final window = a.length < RpcAuthToken._prefixBytes ? a.length : RpcAuthToken._prefixBytes;
  for (var i = 0; i < window; i++) {
    diff |= a[i] ^ b[i];
  }
  // Remaining bytes still go through the fold; the loop above only fixes the
  // window size for short tokens.
  for (var i = window; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
