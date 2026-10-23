/// Where the server is and how to trust it.
///
/// A server installed on a domain uses a publicly trusted certificate and
/// needs nothing more than its address. A server installed on a bare IP may
/// run its own certificate authority instead (see deploy/install.sh); the app
/// then trusts that one CA and nothing else, after the user confirms its
/// fingerprint.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Port of the separate attachment server in development setups, where no
/// proxy multiplexes it onto the main port.
const int devFilePort =
    int.fromEnvironment('FROGSTER_FILE_PORT', defaultValue: 8081);

/// Path at which an installer-managed server publishes its private root CA.
const String caCertificatePath = '/.well-known/frogster-ca.crt';

/// Shortest fingerprint prefix accepted from the user: 128 bits, which no one
/// can match with a different certificate.
const int minFingerprintHexLength = 32;

/// What the app calls itself to the server, shown on the active sessions
/// screen: `Frogster/1.0.1 (windows)`. Dart's default names only the SDK.
final String clientUserAgent =
    'Frogster/${const String.fromEnvironment('FROGSTER_VERSION', defaultValue: '1.0.0')} '
    '(${Platform.operatingSystem})';

class ServerConfig {
  ServerConfig({required this.baseUri, this.caCertificatePem})
      : assert(baseUri.scheme == 'https' || baseUri.scheme == 'http');

  /// Scheme, host and port, without a trailing slash or path.
  final Uri baseUri;

  /// The pinned private root certificate, when the server uses its own CA.
  final String? caCertificatePem;

  bool get isSecure => baseUri.scheme == 'https';
  bool get hasPinnedCa => caCertificatePem != null;

  /// The address as the user would type it.
  String get displayAddress =>
      baseUri.hasPort && baseUri.port != (isSecure ? 443 : 80)
          ? '${baseUri.host}:${baseUri.port}'
          : baseUri.host;

  String get baseUrl => baseUri.toString().replaceAll(RegExp(r'/$'), '');

  Uri get webSocketUri => baseUri.replace(
        scheme: isSecure ? 'wss' : 'ws',
        path: '/v1/ws',
      );

  /// Host and port of the gRPC attachment service. Behind the installer's
  /// proxy it shares the main address; a bare development server runs it on
  /// its own port.
  String get fileHost => baseUri.host;
  int get filePort => isSecure ? baseUri.port : devFilePort;

  /// TLS trust for connections to this server: only the pinned CA when there
  /// is one, the platform's roots otherwise.
  SecurityContext? securityContext() {
    final pem = caCertificatePem;
    if (pem == null) return null;
    return SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(pem));
  }

  HttpClient httpClient() => HttpClient(context: securityContext())
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = clientUserAgent;

  Map<String, dynamic> toJson() => {
        'base': baseUrl,
        if (caCertificatePem != null) 'ca': caCertificatePem,
      };

  static ServerConfig fromJson(Map<String, dynamic> json) => ServerConfig(
        baseUri: Uri.parse(json['base'] as String),
        caCertificatePem: json['ca'] as String?,
      );
}

/// What the user typed into the server field, understood.
class ServerAddress {
  const ServerAddress({required this.baseUri, this.fingerprint});

  final Uri baseUri;

  /// Hex fingerprint (upper case, no separators) from a connection link.
  final String? fingerprint;
}

/// Why a server could not be used. The interface turns these into text in
/// the user's language; [ServerConfigException.toString] is for logs.
enum ServerError {
  noAddress,
  badAddress,
  incompleteLink,
  fingerprintChars,
  fingerprintTooShort,
  noCertificate,
  noCa,
  fingerprintMismatch,
  untrustedCertificate,
  unreachable,
  timeout,
  serverStatus,
  oversizedCertificate,
}

/// Raised when an address or fingerprint cannot be used.
class ServerConfigException implements Exception {
  const ServerConfigException(this.error, [this.status]);

  final ServerError error;

  /// The HTTP status, for [ServerError.serverStatus].
  final int? status;

  @override
  String toString() => status == null
      ? 'ServerConfigException(${error.name})'
      : 'ServerConfigException(${error.name}, $status)';
}

/// Parses a server address.
///
/// Accepts `chat.example.com`, `203.0.113.5`, `host:8443`, full
/// `https://...` URLs, and the `frogster://connect?server=...&ca=...` link
/// the installer prints. Without a scheme, HTTPS is assumed: plain HTTP is
/// for development only and has to be asked for explicitly.
ServerAddress parseServerAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw const ServerConfigException(ServerError.noAddress);
  }

  String? fingerprint;
  if (text.startsWith('frogster://')) {
    final link = Uri.tryParse(text);
    final server = link?.queryParameters['server'];
    if (link == null || server == null) {
      throw const ServerConfigException(ServerError.incompleteLink);
    }
    text = server;
    final ca = link.queryParameters['ca'];
    if (ca != null) fingerprint = normalizeFingerprint(ca);
  }

  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw const ServerConfigException(ServerError.badAddress);
  }
  return ServerAddress(
    baseUri: Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null),
    fingerprint: fingerprint,
  );
}

/// Strips separators and case from a fingerprint the user typed.
String normalizeFingerprint(String input) {
  final hex = input.replaceAll(RegExp(r'[\s:\-]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]+$').hasMatch(hex)) {
    throw const ServerConfigException(ServerError.fingerprintChars);
  }
  if (hex.length < minFingerprintHexLength) {
    throw const ServerConfigException(ServerError.fingerprintTooShort);
  }
  return hex;
}

/// Groups a fingerprint for display the way the installer prints it.
String formatFingerprint(String hex) {
  final short = hex.substring(0, minFingerprintHexLength);
  final groups = <String>[];
  for (var i = 0; i < short.length; i += 4) {
    groups.add(short.substring(i, i + 4));
  }
  return groups.join('-');
}

/// SHA-256 over the DER encoding of the first certificate in [pem], in
/// upper-case hex -- the same value `frogster fingerprint` prints.
Future<String> certificateFingerprint(String pem) async {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) {
    throw const ServerConfigException(ServerError.noCertificate);
  }
  final der = base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  final hash = await Sha256().hash(der);
  return hash.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// Downloads the server's private root certificate and checks it against the
/// fingerprint the user confirmed.
///
/// The download skips certificate validation on purpose: the server's TLS
/// certificate is issued by the very CA being fetched, so it cannot be
/// validated yet. Trust comes from the fingerprint comparison, not from the
/// channel -- a substituted certificate has a different fingerprint.
Future<ServerConfig> pinServerCa(Uri baseUri, String fingerprint) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (_, _, _) => true;
  try {
    final request =
        await client.getUrl(baseUri.replace(path: caCertificatePath));
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      throw const ServerConfigException(ServerError.noCa);
    }
    final bytes = await _readLimited(response, 64 * 1024);
    final pem = utf8.decode(bytes, allowMalformed: true);
    final actual = await certificateFingerprint(pem);
    if (!actual.startsWith(fingerprint)) {
      throw const ServerConfigException(ServerError.fingerprintMismatch);
    }
    return ServerConfig(baseUri: baseUri, caCertificatePem: pem);
  } on SocketException {
    throw const ServerConfigException(ServerError.unreachable);
  } on TimeoutException {
    throw const ServerConfigException(ServerError.timeout);
  } finally {
    client.close(force: true);
  }
}

/// Checks that the server answers over the given configuration.
///
/// Distinguishes the one failure the user can fix by themselves -- a server
/// running its own CA, which needs a fingerprint -- from plain unreachability.
Future<void> probeServer(ServerConfig config) async {
  final client = config.httpClient();
  try {
    final request = await client.getUrl(config.baseUri.replace(path: '/healthz'));
    final response = await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>();
    if (response.statusCode != HttpStatus.ok) {
      throw ServerConfigException(ServerError.serverStatus, response.statusCode);
    }
  } on HandshakeException {
    throw const ServerCertificateUntrusted();
  } on TlsException {
    throw const ServerCertificateUntrusted();
  } on SocketException {
    throw const ServerConfigException(ServerError.unreachable);
  } on TimeoutException {
    throw const ServerConfigException(ServerError.timeout);
  } finally {
    client.close(force: true);
  }
}

/// The server's certificate is not trusted: it needs a pinned fingerprint.
class ServerCertificateUntrusted extends ServerConfigException {
  const ServerCertificateUntrusted() : super(ServerError.untrustedCertificate);
}

Future<Uint8List> _readLimited(Stream<List<int>> stream, int limit) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
    if (builder.length > limit) {
      throw const ServerConfigException(ServerError.oversizedCertificate);
    }
  }
  return builder.takeBytes();
}
