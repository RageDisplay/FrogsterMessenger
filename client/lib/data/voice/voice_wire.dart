/// Voice datagrams, as the server's relay reads and writes them
/// (server/internal/voice/packet.go):
///
///     0       version (1)
///     1..8    tag: which member's keys
///     9..16   counter, big-endian, never repeating under one key
///     17..    AES-256-GCM ciphertext, the header as associated data
///
/// Each member gets a secret when joining, over TLS; two keys come from it,
/// one each way, so the app's counter and the relay's can never meet under
/// one key.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';

const int _version = 1;
const int _tagSize = 8;
const int _headerSize = 1 + _tagSize + 8;
const int _tagLength = 16;

/// Kinds of plaintext.
abstract final class VoiceKind {
  static const audio = 1;
  static const ping = 2;
  static const pong = 3;
}

/// Bounds a datagram, as the relay does.
const int maxVoiceDatagram = 1400;

/// What arrived from the relay, opened.
sealed class VoiceInbound {
  const VoiceInbound();
}

/// Someone's 20 ms of sound.
class VoiceAudio extends VoiceInbound {
  const VoiceAudio(this.member, this.seq, this.opus);
  final int member;
  final int seq;
  final Uint8List opus;
}

/// The answer to a ping, echoing what it carried.
class VoicePong extends VoiceInbound {
  const VoicePong(this.body);
  final Uint8List body;
}

/// One member's keys: sealing what goes to the relay, opening what comes
/// back.
class VoiceCipher {
  VoiceCipher({required Uint8List tag, required Uint8List secret})
      : _tag = Uint8List.fromList(tag),
        _up = _derive(secret, 'frogster/voice/v1/up'),
        _down = _derive(secret, 'frogster/voice/v1/down') {
    if (tag.length != _tagSize) throw ArgumentError('a tag is $_tagSize bytes');
    if (secret.length != 32) throw ArgumentError('a secret is 32 bytes');
  }

  final Uint8List _tag;
  final Uint8List _up;
  final Uint8List _down;

  /// Last counter used going up. Starts at 0: the first datagram is 1.
  int _counter = 0;

  /// Newest counter seen coming down, and which of the 64 before it were.
  int _newest = 0;
  int _seen = 0;

  static Uint8List _derive(Uint8List secret, String info) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())..init(HkdfParameters(secret, 32, null, utf8.encode(info)));
    final key = Uint8List(32);
    hkdf.deriveKey(null, 0, key, 0);
    return key;
  }

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  static GCMBlockCipher _gcm(Uint8List key, int counter, Uint8List aad, {required bool encrypt}) =>
      GCMBlockCipher(AESEngine())
        ..init(encrypt, AEADParameters(KeyParameter(key), _tagLength * 8, _nonce(counter), aad));

  /// Seals [plaintext] under the up key with the next counter.
  Uint8List seal(Uint8List plaintext) => sealAt(++_counter, plaintext);

  /// Seals with a given counter: for tests against the relay's vectors.
  Uint8List sealAt(int counter, Uint8List plaintext, {bool down = false}) {
    final header = Uint8List(_headerSize);
    header[0] = _version;
    header.setAll(1, _tag);
    ByteData.sublistView(header).setUint64(1 + _tagSize, counter);
    final gcm = _gcm(down ? _down : _up, counter, header, encrypt: true);
    final body = gcm.process(plaintext);
    return Uint8List(_headerSize + body.length)
      ..setAll(0, header)
      ..setAll(_headerSize, body);
  }

  /// A packet of sound to send.
  Uint8List audio(int seq, Uint8List opus) {
    final plain = Uint8List(3 + opus.length);
    plain[0] = VoiceKind.audio;
    ByteData.sublistView(plain).setUint16(1, seq & 0xffff);
    plain.setAll(3, opus);
    return seal(plain);
  }

  /// A ping, keeping the path open and measuring it; [body] comes back.
  Uint8List ping(Uint8List body) => seal(Uint8List.fromList([VoiceKind.ping, ...body]));

  /// Authenticates and decrypts under [key]; null for anything that fails.
  (int, Uint8List)? _unseal(Uint8List datagram, Uint8List key) {
    if (datagram.length < _headerSize + _tagLength || datagram.length > maxVoiceDatagram) return null;
    if (datagram[0] != _version) return null;
    for (var i = 0; i < _tagSize; i++) {
      if (datagram[1 + i] != _tag[i]) return null;
    }
    final counter = ByteData.sublistView(datagram).getUint64(1 + _tagSize);
    try {
      final gcm = _gcm(key, counter, Uint8List.sublistView(datagram, 0, _headerSize), encrypt: false);
      return (counter, gcm.process(Uint8List.sublistView(datagram, _headerSize)));
    } on InvalidCipherTextException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// What the relay reads in one of our datagrams: for a stand-in relay in
  /// tests.
  @visibleForTesting
  Uint8List? openAsRelay(Uint8List datagram) => _unseal(datagram, _up)?.$2;

  /// Opens a datagram from the relay. Null for anything that is not one: a
  /// wrong tag, a failed check, a replay, junk.
  VoiceInbound? open(Uint8List datagram) {
    final opened = _unseal(datagram, _down);
    if (opened == null) return null;
    final (counter, plain) = opened;
    if (!_accept(counter) || plain.isEmpty) return null;
    switch (plain[0]) {
      case VoiceKind.audio when plain.length >= 1 + 4 + 2 + 1:
        final view = ByteData.sublistView(plain);
        return VoiceAudio(view.getUint32(1), view.getUint16(5), Uint8List.sublistView(plain, 7));
      case VoiceKind.pong:
        return VoicePong(Uint8List.sublistView(plain, 1));
      default:
        return null;
    }
  }

  /// Takes each counter once, allowing for the reordering a network does.
  bool _accept(int counter) {
    if (counter <= 0) return false;
    if (counter > _newest) {
      final shift = counter - _newest;
      _seen = shift >= 64 ? 1 : _seen << shift | 1;
      _newest = counter;
      return true;
    }
    final behind = _newest - counter;
    if (behind >= 64 || (_seen >> behind) & 1 != 0) return false;
    _seen |= 1 << behind;
    return true;
  }
}
