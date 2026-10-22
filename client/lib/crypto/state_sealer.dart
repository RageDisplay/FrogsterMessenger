/// Encrypts key material before it goes into the local database.
///
/// Ratchet sessions and sender keys are too large and change too often for
/// the platform keychain, so they live in SQLite. Stored as plain JSON, a copy
/// of the database file -- a backup, a stolen laptop's disk image -- would
/// carry live chain keys: everything needed to read the conversations they
/// belong to. Sealed with a key that stays in the keychain, the file alone is
/// useless.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'primitives.dart';

/// Seals and opens database values with one key from the keychain.
class StateSealer {
  StateSealer(Uint8List key) : _key = Uint8List.fromList(key) {
    if (key.length != symmetricKeyLength) {
      throw ArgumentError('state key must be $symmetricKeyLength bytes');
    }
  }

  final Uint8List _key;

  /// Marks a sealed value. Anything without it is a value written before
  /// sealing existed, read as is and sealed the next time it is saved.
  static const _prefix = 's1:';

  /// Seals [json] for the row named by [label] -- table and key -- so a
  /// value copied to another row fails to open instead of being used there.
  Future<String> seal(String label, String json) async {
    final sealed = await aeadEncrypt(
      key: _key,
      plaintext: utf8.encode(json),
      associatedData: utf8.encode(label),
    );
    return '$_prefix${base64Encode(sealed.serialize())}';
  }

  /// Opens a value written by [seal], or passes through a legacy plaintext
  /// one. Throws when a sealed value fails to authenticate.
  Future<String> open(String label, String stored) async {
    if (!stored.startsWith(_prefix)) return stored;
    final plain = await aeadDecrypt(
      key: _key,
      ciphertext: AeadCiphertext.deserialize(
        base64Decode(stored.substring(_prefix.length)),
      ),
      associatedData: utf8.encode(label),
    );
    return utf8.decode(plain);
  }

  /// Whether [stored] was written by [seal].
  static bool isSealed(String stored) => stored.startsWith(_prefix);
}
