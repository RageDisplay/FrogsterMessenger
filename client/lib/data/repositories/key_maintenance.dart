/// Keeps this device's published keys healthy.
///
/// Two chores, both run at sign-in and daily after that:
///   * one-time prekeys are consumed by every new session other people start
///     with us; once the server's pool is empty, new sessions lose the extra
///     forward secrecy those keys provide;
///   * the signed prekey is replaced weekly, bounding how much a stolen
///     device can reveal about past session starts.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../crypto/crypto_engine.dart';

/// How many one-time prekeys are uploaded when the pool runs low.
const int preKeyReplenishBatch = 100;

class KeyMaintenance {
  KeyMaintenance({
    required CryptoEngine crypto,
    required Future<({int available, bool shouldReplenish})> Function()
        preKeyCount,
    required Future<void> Function(Map<int, Uint8List> keys) uploadPreKeys,
    required Future<void> Function(SignedPreKeyUpload upload)
        uploadSignedPreKey,
  })  : _crypto = crypto,
        _preKeyCount = preKeyCount,
        _uploadPreKeys = uploadPreKeys,
        _uploadSignedPreKey = uploadSignedPreKey;

  final CryptoEngine _crypto;
  final Future<({int available, bool shouldReplenish})> Function() _preKeyCount;
  final Future<void> Function(Map<int, Uint8List>) _uploadPreKeys;
  final Future<void> Function(SignedPreKeyUpload) _uploadSignedPreKey;

  Timer? _timer;
  Future<void>? _running;

  /// Runs now and then once a day until [stop].
  void start() {
    unawaited(run());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 24), (_) => run());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Performs both chores. Failures are swallowed and retried on the next
  /// run: neither is urgent, and a flaky network must not surface as an
  /// error the user can do nothing about.
  Future<void> run() => _running ??= _run().whenComplete(() => _running = null);

  Future<void> _run() async {
    try {
      await replenishPreKeys();
    } catch (e) {
      // ignore: avoid_print
      print('[frogster] prekey replenishment failed: $e');
    }
    try {
      await rotateSignedPreKey();
    } catch (e) {
      // ignore: avoid_print
      print('[frogster] signed prekey rotation failed: $e');
    }
  }

  Future<void> replenishPreKeys() async {
    final count = await _preKeyCount();
    if (!count.shouldReplenish) return;
    final keys = await _crypto.generateOneTimePreKeys(preKeyReplenishBatch);
    await _uploadPreKeys(keys);
  }

  /// Commits the new key locally only after the server accepted it. The
  /// other order would leave the server handing out a key this device no
  /// longer holds whenever the upload failed.
  Future<void> rotateSignedPreKey() async {
    final upload = await _crypto.prepareSignedPreKeyRotation();
    if (upload == null) return;
    await _uploadSignedPreKey(upload);
    await _crypto.commitSignedPreKeyRotation(upload);
  }
}
