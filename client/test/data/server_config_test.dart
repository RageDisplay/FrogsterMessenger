import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/remote/server_config.dart';

/// A throwaway self-signed certificate and the fingerprint openssl computes
/// for it (`openssl x509 -outform der | sha256sum`), which is what the
/// installer prints.
const _testCa = '''
-----BEGIN CERTIFICATE-----
MIIBkDCCATWgAwIBAgIUO5GpJIzvIBVSIAfHzFqpbYOYe7gwCgYIKoZIzj0EAwIw
HTEbMBkGA1UEAwwSRnJvZ3N0ZXIgVGVzdCBSb290MB4XDTI2MTAxOTExMzEwOVoX
DTM2MTAxNjExMzEwOVowHTEbMBkGA1UEAwwSRnJvZ3N0ZXIgVGVzdCBSb290MFkw
EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYi+vCWHnEo8RYyAJY93RcLlD9QmB2ITX
O3iu/8KAUufL0OOPSbO+Ah0oHHMS9ckqkwgjSv5DYLagvSg60XeaHqNTMFEwHQYD
VR0OBBYEFNe8tmqDc6YGV0yoApM7pif74D2DMB8GA1UdIwQYMBaAFNe8tmqDc6YG
V0yoApM7pif74D2DMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIh
APYNAdwIOK7cghDLUcjYo7hwm1oqcvD56fCu30GWTk2EAiEAongNhR0tdzQNQX7H
Q76RRJmg6zrl+ToaMYE966WMH3o=
-----END CERTIFICATE-----
''';
const _testCaFingerprint =
    'DC8E269C73F8B7EAF012D87D01BF672F7780328BA7628B1B73AE0B3A8BAFBF01';

void main() {
  group('parseServerAddress', () {
    test('assumes HTTPS for a bare host', () {
      final a = parseServerAddress('chat.example.com');
      expect(a.baseUri.toString(), 'https://chat.example.com');
      expect(a.fingerprint, isNull);
    });

    test('keeps an explicit port and drops any path', () {
      final a = parseServerAddress('https://203.0.113.5:8443/whatever');
      expect(a.baseUri.toString(), 'https://203.0.113.5:8443');
    });

    test('allows plain HTTP only when asked for explicitly', () {
      expect(parseServerAddress('http://10.0.2.2:18080').baseUri.scheme, 'http');
      expect(parseServerAddress('10.0.2.2').baseUri.scheme, 'https');
    });

    test('reads the installer connection link', () {
      final a = parseServerAddress(
        'frogster://connect?server=https://203.0.113.5&ca=$_testCaFingerprint',
      );
      expect(a.baseUri.toString(), 'https://203.0.113.5');
      expect(a.fingerprint, _testCaFingerprint);
    });

    test('rejects nonsense', () {
      expect(() => parseServerAddress(''), throwsA(isA<ServerConfigException>()));
      expect(() => parseServerAddress('ftp://x'),
          throwsA(isA<ServerConfigException>()));
    });
  });

  group('fingerprints', () {
    test('normalises the grouped form the installer prints', () {
      expect(
        normalizeFingerprint('dc8e-269c-73f8-b7ea-f012-d87d-01bf-672f'),
        'DC8E269C73F8B7EAF012D87D01BF672F',
      );
    });

    test('refuses a prefix too short to be safe', () {
      expect(() => normalizeFingerprint('DC8E-269C'),
          throwsA(isA<ServerConfigException>()));
    });

    test('refuses characters that are not hex', () {
      expect(() => normalizeFingerprint('ZZ8E269C73F8B7EAF012D87D01BF672F'),
          throwsA(isA<ServerConfigException>()));
    });

    test('matches openssl for a real certificate', () async {
      // The app and the installer must compute the same value, or users
      // would be told their genuine server is being intercepted.
      expect(await certificateFingerprint(_testCa), _testCaFingerprint);
    });

    test('formats like the installer', () {
      expect(formatFingerprint(_testCaFingerprint),
          'DC8E-269C-73F8-B7EA-F012-D87D-01BF-672F');
    });
  });

  group('ServerConfig', () {
    test('derives the WebSocket and attachment endpoints', () {
      final secure = ServerConfig(baseUri: Uri.parse('https://chat.example.com'));
      expect(secure.webSocketUri.toString(), 'wss://chat.example.com/v1/ws');
      expect(secure.filePort, 443);

      final dev = ServerConfig(baseUri: Uri.parse('http://10.0.2.2:18080'));
      expect(dev.webSocketUri.toString(), 'ws://10.0.2.2:18080/v1/ws');
      expect(dev.filePort, devFilePort);
    });

    test('survives a round trip through storage with its pinned CA', () {
      final config = ServerConfig(
        baseUri: Uri.parse('https://203.0.113.5'),
        caCertificatePem: _testCa,
      );
      final restored = ServerConfig.fromJson(config.toJson());
      expect(restored.baseUri, config.baseUri);
      expect(restored.caCertificatePem, _testCa);
      expect(restored.securityContext(), isNotNull);
    });
  });
}
