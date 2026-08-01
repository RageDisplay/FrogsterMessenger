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
const String _kOneTimePreKeyPrefix = 'frogster.otp.';
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
  Future<void> saveOneTimePreKey(int keyId, KeyPair pair);
  Future<KeyPair?> loadOneTimePreKey(int keyId);
  Future<void> deleteOneTimePreKey(int keyId);
  Future<void> saveRegistrationId(int id);
  Future<int?> loadRegistrationId();
  Future<void> saveDeviceId(String id);
  Future<String?> loadDeviceId();
  Future<void> wipeAll();
}

/// Stores private keys in the platform keychain.
class SecureKeyStorage implements KeyStorage {
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

  /// True when this device already has an identity.
  @override
  Future<bool> hasIdentity() async {
    final value = await _storage.read(key: _kIdentityDhPrivate);
    return value != null;
  }

  /// Creates and stores a new device identity.
  ///
  /// Called once, on first launch. Both key pairs are generated locally; only
  /// the public halves are ever uploaded.
  @override
  Future<IdentityKeys> createIdentity() async {
    final dh = await generateKeyPair();
    final signing = await generateSigningKeyPair();

    await _storage.write(
      key: _kIdentityDhPrivate,
      value: base64Encode(dh.privateKey),
    );
    await _storage.write(
      key: _kIdentitySigningSeed,
      value: base64Encode(signing.seed),
    );

    return IdentityKeys(dhKeyPair: dh, signingKeyPair: signing);
  }

  /// Loads the stored identity, or null when this device has none yet.
  @override
  Future<IdentityKeys?> loadIdentity() async {
    final dhPrivate = await _storage.read(key: _kIdentityDhPrivate);
    final signingSeed = await _storage.read(key: _kIdentitySigningSeed);
    if (dhPrivate == null || signingSeed == null) return null;

    return IdentityKeys(
      dhKeyPair: await keyPairFromPrivateKey(base64Decode(dhPrivate)),
      signingKeyPair: await signingKeyPairFromSeed(base64Decode(signingSeed)),
    );
  }

  /// Stores the current signed prekey together with its signature.
  @override
  Future<void> saveSignedPreKey(SignedPreKeyPair spk) async {
    await _storage.write(
      key: _kSignedPreKeyPrivate,
      value: base64Encode(spk.keyPair.privateKey),
    );
    await _storage.write(key: _kSignedPreKeyId, value: spk.keyId.toString());
    await _storage.write(
      key: _kSignedPreKeySignature,
      value: base64Encode(spk.signature),
    );
  }

  /// Loads the current signed prekey.
  @override
  Future<SignedPreKeyPair?> loadSignedPreKey() async {
    final private = await _storage.read(key: _kSignedPreKeyPrivate);
    final id = await _storage.read(key: _kSignedPreKeyId);
    final signature = await _storage.read(key: _kSignedPreKeySignature);
    if (private == null || id == null || signature == null) return null;

    return SignedPreKeyPair(
      keyId: int.parse(id),
      keyPair: await keyPairFromPrivateKey(base64Decode(private)),
      signature: base64Decode(signature),
    );
  }

  /// Stores the private half of a one-time prekey.
  @override
  Future<void> saveOneTimePreKey(int keyId, KeyPair pair) async {
    await _storage.write(
      key: '$_kOneTimePreKeyPrefix$keyId',
      value: base64Encode(pair.privateKey),
    );
  }

  /// Loads a one-time prekey by id.
  @override
  Future<KeyPair?> loadOneTimePreKey(int keyId) async {
    final value = await _storage.read(key: '$_kOneTimePreKeyPrefix$keyId');
    if (value == null) return null;
    return keyPairFromPrivateKey(base64Decode(value));
  }

  /// Deletes a one-time prekey once a session has consumed it.
  ///
  /// Retaining it would defeat the point: the forward secrecy a one-time
  /// prekey provides depends on the private half being destroyed after use.
  @override
  Future<void> deleteOneTimePreKey(int keyId) async {
    await _storage.delete(key: '$_kOneTimePreKeyPrefix$keyId');
  }

  /// Stores this device's registration id.
  @override
  Future<void> saveRegistrationId(int id) async {
    await _storage.write(key: _kRegistrationId, value: id.toString());
  }

  /// Loads this device's registration id.
  @override
  Future<int?> loadRegistrationId() async {
    final value = await _storage.read(key: _kRegistrationId);
    return value == null ? null : int.parse(value);
  }

  /// Records the device id the server issued.
  @override
  Future<void> saveDeviceId(String id) async {
    await _storage.write(key: _kDeviceId, value: id);
  }

  /// The device id from a previous registration, if this install has one.
  @override
  Future<String?> loadDeviceId() => _storage.read(key: _kDeviceId);

  /// Erases every stored key.
  ///
  /// Used on logout and on account deletion. After this the device cannot
  /// decrypt any past message, which is the intended behaviour.
  @override
  Future<void> wipeAll() async {
    await _storage.deleteAll();
  }
}

/// An in-memory implementation for tests and for platforms without a keychain.
///
/// This is NOT secure storage: it keeps keys in the process heap and loses
/// them on restart. It exists so unit tests can run without a platform
/// channel, and must never be selected on a real device.
class InMemoryKeyStorage implements KeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<bool> hasIdentity() async => _values.containsKey(_kIdentityDhPrivate);

  @override
  Future<IdentityKeys> createIdentity() async {
    final dh = await generateKeyPair();
    final signing = await generateSigningKeyPair();
    _values[_kIdentityDhPrivate] = base64Encode(dh.privateKey);
    _values[_kIdentitySigningSeed] = base64Encode(signing.seed);
    return IdentityKeys(dhKeyPair: dh, signingKeyPair: signing);
  }

  @override
  Future<IdentityKeys?> loadIdentity() async {
    final dhPrivate = _values[_kIdentityDhPrivate];
    final signingSeed = _values[_kIdentitySigningSeed];
    if (dhPrivate == null || signingSeed == null) return null;
    return IdentityKeys(
      dhKeyPair: await keyPairFromPrivateKey(base64Decode(dhPrivate)),
      signingKeyPair: await signingKeyPairFromSeed(base64Decode(signingSeed)),
    );
  }

  @override
  Future<void> saveSignedPreKey(SignedPreKeyPair spk) async {
    _values[_kSignedPreKeyPrivate] = base64Encode(spk.keyPair.privateKey);
    _values[_kSignedPreKeyId] = spk.keyId.toString();
    _values[_kSignedPreKeySignature] = base64Encode(spk.signature);
  }

  @override
  Future<SignedPreKeyPair?> loadSignedPreKey() async {
    final private = _values[_kSignedPreKeyPrivate];
    final id = _values[_kSignedPreKeyId];
    final signature = _values[_kSignedPreKeySignature];
    if (private == null || id == null || signature == null) return null;
    return SignedPreKeyPair(
      keyId: int.parse(id),
      keyPair: await keyPairFromPrivateKey(base64Decode(private)),
      signature: base64Decode(signature),
    );
  }

  @override
  Future<void> saveOneTimePreKey(int keyId, KeyPair pair) async {
    _values['$_kOneTimePreKeyPrefix$keyId'] = base64Encode(pair.privateKey);
  }

  @override
  Future<KeyPair?> loadOneTimePreKey(int keyId) async {
    final value = _values['$_kOneTimePreKeyPrefix$keyId'];
    if (value == null) return null;
    return keyPairFromPrivateKey(base64Decode(value));
  }

  @override
  Future<void> deleteOneTimePreKey(int keyId) async {
    _values.remove('$_kOneTimePreKeyPrefix$keyId');
  }

  @override
  Future<void> saveRegistrationId(int id) async {
    _values[_kRegistrationId] = id.toString();
  }

  @override
  Future<int?> loadRegistrationId() async {
    final value = _values[_kRegistrationId];
    return value == null ? null : int.parse(value);
  }

  @override
  Future<void> saveDeviceId(String id) async {
    _values[_kDeviceId] = id;
  }

  @override
  Future<String?> loadDeviceId() async => _values[_kDeviceId];

  @override
  Future<void> wipeAll() async => _values.clear();
}
