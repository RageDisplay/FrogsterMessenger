/// Persists who is signed in, to which server, so a restart does not ask for
/// the password again.
///
/// Lives in the platform keychain alongside the identity keys: the refresh
/// token is as good as a password until it expires or is revoked.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';
import '../remote/server_config.dart';

const String _kServer = 'frogster.session.server';
const String _kAccount = 'frogster.session.account';
const String _kRefreshToken = 'frogster.session.refresh_token';

/// A signed-in session as stored between launches.
class StoredSession {
  const StoredSession({
    required this.server,
    required this.account,
    required this.refreshToken,
  });

  final ServerConfig server;
  final Account account;
  final String refreshToken;
}

/// Key-value persistence, so tests can run without a platform channel.
abstract class SecureValues {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecureValues implements SecureValues {
  PlatformSecureValues([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecureValues implements SecureValues {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class AccountStore {
  AccountStore([SecureValues? values]) : _values = values ?? PlatformSecureValues();

  final SecureValues _values;

  /// The server last used, remembered even after signing out so the login
  /// screen can offer it again.
  Future<ServerConfig?> loadServer() async {
    final raw = await _values.read(_kServer);
    if (raw == null) return null;
    try {
      return ServerConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveServer(ServerConfig server) =>
      _values.write(_kServer, jsonEncode(server.toJson()));

  Future<StoredSession?> loadSession() async {
    final server = await loadServer();
    final rawAccount = await _values.read(_kAccount);
    final refresh = await _values.read(_kRefreshToken);
    if (server == null || rawAccount == null || refresh == null) return null;
    try {
      final json = jsonDecode(rawAccount) as Map<String, dynamic>;
      return StoredSession(
        server: server,
        account: Account(
          userId: json['user_id'] as String,
          username: json['username'] as String,
          deviceId: json['device_id'] as String,
        ),
        refreshToken: refresh,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession({
    required ServerConfig server,
    required Account account,
    required String refreshToken,
  }) async {
    await saveServer(server);
    await _values.write(
      _kAccount,
      jsonEncode({
        'user_id': account.userId,
        'username': account.username,
        'device_id': account.deviceId,
      }),
    );
    await _values.write(_kRefreshToken, refreshToken);
  }

  /// Stores a rotated refresh token. Must be written before the old one is
  /// used again, or a crash in between leaves only a revoked token behind.
  Future<void> saveRefreshToken(String token) =>
      _values.write(_kRefreshToken, token);

  /// Forgets the session but keeps the server, for the next sign-in.
  Future<void> clearSession() async {
    await _values.delete(_kAccount);
    await _values.delete(_kRefreshToken);
  }
}
