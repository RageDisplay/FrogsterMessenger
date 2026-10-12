/// Persistence for private key material.
///
/// Private keys never leave the device. They live in the platform keychain
/// (Keychain on Apple platforms, KeyStore on Android, DPAPI on Windows,
/// libsecret on Linux) rather than in the message database, so a stolen
/// database file alone does not yield the ability to decrypt anything.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'primitives.dart';
import 'signing.dart';
import 'x3dh.dart';

/// Keys under which material is stored.
const String _kIdentityDhPrivate = 'frogster.identity.dh.private';
const String _kIdentitySigningSeed = 'frogster.identity.signing.seed';
const String _kSignedPreKeyPrivate = 'frogster.spk.private';
const String _kSignedPreKeyId = 'frogster.spk.id';
const String _kSignedPreKeySignature = 'frogster.spk.signature';
const String _kSignedPreKeyCreatedAt = 'frogster.spk.created_at';
const String _kPreviousSignedPreKey = 'frogster.spk.previous';
const String _kOneTimePreKeyPrefix = 'frogster.otp.';
const String _kNextOneTimePreKeyId = 'frogster.otp_next_id';
const String _kRegistrationId = 'frogster.registration_id';

/// The server-assigned device id, stored after the first registration.
///
/// Without it a returning user would have to register a new device on every
/// sign-in, which collides with UNIQUE(user_id, registration_id) and locks
/// them out of their own account.
const String _kDeviceId = 'frogster.device_id';

/// Persistence contract for private key material.
///
/// Declared as an interface so tests can substitute an in-memory
/// implementation without a platform channel, and so a future platform with a
/// different keystore can be added without touching the protocol code.
abstract class KeyStorage {
  Future<bool> hasIdentity();
  Future<IdentityKeys> createIdentity();
  Future<IdentityKeys?> loadIdentity();
  Future<void> saveSignedPreKey(SignedPreKeyPair spk);
  Future<SignedPreKeyPair?> loadSignedPreKey();

  /// The signed prekey replaced by the most recent rotation.
  ///
  /// Kept for a grace period because a prekey message encrypted against it
  /// may still be in flight, or queued for this device while it was offline.
  Future<void> savePreviousSignedPreKey(SignedPreKeyPair? spk);
  Future<SignedPreKeyPair?> loadPreviousSignedPreKey();

  Future<void> saveOneTimePreKey(int keyId, KeyPair pair);
  Future<KeyPair?> loadOneTimePreKey(int keyId);
  Future<void> deleteOneTimePreKey(int keyId);

  /// The id the next generated one-time prekey takes.
  ///
  /// Ids must never repeat while the server may still hold the old key under
  /// the same id: a new private key saved over it would make every session
  /// built from the old public key fail.
  Future<int?> loadNextOneTimePreKeyId();
  Future<void> saveNextOneTimePreKeyId(int id);

  Future<void> saveRegistrationId(int id);
  Future<int?> loadRegistrationId();
  Future<void> saveDeviceId(String id);
  Future<String?> loadDeviceId();
  Future<void> wipeAll();
}

/// Key-value persistence shared by [SecureKeyStorage] and
/// [InMemoryKeyStorage], so the two cannot drift apart in encoding.
abstract class _StringKeyStorage implements KeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  @override
  Future<bool> hasIdentity() async => await read(_kIdentityDhPrivate) != null;

  /// Creates and stores a new device identity.
  ///
  /// Called once, on first launch. Both key pairs are generated locally; only
  /// the public halves are ever uploaded.
  @override
  Future<IdentityKeys> createIdentity() async {
    final dh = await generateKeyPair();
    final signing = await generateSigningKeyPair();
    await write(_kIdentityDhPrivate, base64Encode(dh.privateKey));
    await write(_kIdentitySigningSeed, base64Encode(signing.seed));
    return IdentityKeys(dhKeyPair: dh, signingKeyPair: signing);
  }

  @override
  Future<IdentityKeys?> loadIdentity() async {
    final dhPrivate = await read(_kIdentityDhPrivate);
    final signingSeed = await read(_kIdentitySigningSeed);
    if (dhPrivate == null || signingSeed == null) return null;
    return IdentityKeys(
      dhKeyPair: await keyPairFromPrivateKey(base64Decode(dhPrivate)),
      signingKeyPair: await signingKeyPairFromSeed(base64Decode(signingSeed)),
    );
  }

  /// Stores the current signed prekey together with its signature.
  ///
  /// The legacy one-field-per-key layout is kept for the current key so that
  /// installs from before rotation existed keep their key.
  @override
  Future<void> saveSignedPreKey(SignedPreKeyPair spk) async {
    await write(_kSignedPreKeyPrivate, base64Encode(spk.keyPair.privateKey));
    await write(_kSignedPreKeyId, spk.keyId.toString());
    await write(_kSignedPreKeySignature, base64Encode(spk.signature));
    if (spk.createdAt != null) {
      await write(
        _kSignedPreKeyCreatedAt,
        spk.createdAt!.toUtc().toIso8601String(),
      );
    } else {
      await delete(_kSignedPreKeyCreatedAt);
    }
  }

  @override
  Future<SignedPreKeyPair?> loadSignedPreKey() async {
    final private = await read(_kSignedPreKeyPrivate);
    final id = await read(_kSignedPreKeyId);
    final signature = await read(_kSignedPreKeySignature);
    if (private == null || id == null || signature == null) return null;
    final createdAt = await read(_kSignedPreKeyCreatedAt);
    return SignedPreKeyPair(
      keyId: int.parse(id),
      keyPair: await keyPairFromPrivateKey(base64Decode(private)),
      signature: base64Decode(signature),
      createdAt: createdAt == null ? null : DateTime.parse(createdAt),
    );
  }

  @override
  Future<void> savePreviousSignedPreKey(SignedPreKeyPair? spk) async {
    if (spk == null) {
      await delete(_kPreviousSignedPreKey);
      return;
    }
    await write(
      _kPreviousSignedPreKey,
      jsonEncode({
        'id': spk.keyId,
        'private': base64Encode(spk.keyPair.privateKey),
        'signature': base64Encode(spk.signature),
        if (spk.createdAt != null)
          'created_at': spk.createdAt!.toUtc().toIso8601String(),
      }),
    );
  }

  @override
  Future<SignedPreKeyPair?> loadPreviousSignedPreKey() async {
    final raw = await read(_kPreviousSignedPreKey);
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final createdAt = json['created_at'] as String?;
    return SignedPreKeyPair(
      keyId: json['id'] as int,
      keyPair: await keyPairFromPrivateKey(
        base64Decode(json['private'] as String),
      ),
      signature: base64Decode(json['signature'] as String),
      createdAt: createdAt == null ? null : DateTime.parse(createdAt),
    );
  }

  @override
  Future<void> saveOneTimePreKey(int keyId, KeyPair pair) =>
      write('$_kOneTimePreKeyPrefix$keyId', base64Encode(pair.privateKey));

  @override
  Future<KeyPair?> loadOneTimePreKey(int keyId) async {
    final value = await read('$_kOneTimePreKeyPrefix$keyId');
    if (value == null) return null;
    return keyPairFromPrivateKey(base64Decode(value));
  }

  /// Deletes a one-time prekey once a session has consumed it.
  ///
  /// Retaining it would defeat the point: the forward secrecy a one-time
  /// prekey provides depends on the private half being destroyed after use.
  @override
  Future<void> deleteOneTimePreKey(int keyId) =>
      delete('$_kOneTimePreKeyPrefix$keyId');

  @override
  Future<int?> loadNextOneTimePreKeyId() async {
    final value = await read(_kNextOneTimePreKeyId);
    return value == null ? null : int.parse(value);
  }

  @override
  Future<void> saveNextOneTimePreKeyId(int id) =>
      write(_kNextOneTimePreKeyId, id.toString());

  @override
  Future<void> saveRegistrationId(int id) =>
      write(_kRegistrationId, id.toString());

  @override
  Future<int?> loadRegistrationId() async {
    final value = await read(_kRegistrationId);
    return value == null ? null : int.parse(value);
  }

  /// Records the device id the server issued.
  @override
  Future<void> saveDeviceId(String id) => write(_kDeviceId, id);

  /// The device id from a previous registration, if this install has one.
  @override
  Future<String?> loadDeviceId() => read(_kDeviceId);
}

/// Stores private keys in the platform keychain.
class SecureKeyStorage extends _StringKeyStorage {
  SecureKeyStorage({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              // Keys stay unreadable until the device is first unlocked
              // after boot, and never sync to another device.
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

  /// Erases every stored key.
  ///
  /// Used on logout and on account deletion. After this the device cannot
  /// decrypt any past message, which is the intended behaviour.
  @override
  Future<void> wipeAll() => _storage.deleteAll();
}

/// An in-memory implementation for tests and for platforms without a keychain.
///
/// This is NOT secure storage: it keeps keys in the process heap and loses
/// them on restart. It exists so unit tests can run without a platform
/// channel, and must never be selected on a real device.
class InMemoryKeyStorage extends _StringKeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> wipeAll() async => _values.clear();
}
