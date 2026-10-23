/// Opus packets in an Ogg file (RFC 7845), so a saved voice message plays
/// in any player.
library;

import 'dart:typed_data';

import 'native.dart' show sampleRate;

/// Samples the decoder drops from the start: the encoder's look-ahead at
/// 48 kHz for speech.
const int opusPreSkip = 312;

/// Builds an Ogg Opus stream from packets of 20 ms speech.
class OggOpusWriter {
  OggOpusWriter({int? serial}) : _serial = serial ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff {
    _page(_head(), granule: 0, flags: 0x02);
    _page(_tags(), granule: 0);
  }

  final int _serial;
  final _out = BytesBuilder(copy: false);
  var _sequence = 0;
  var _granule = opusPreSkip;
  final _pending = <Uint8List>[];

  /// Packets per page: about a second of speech.
  static const _packetsPerPage = 50;

  /// Adds one packet holding [samples] samples.
  void add(Uint8List packet, int samples) {
    _pending.add(packet);
    _granule += samples;
    if (_pending.length == _packetsPerPage) _flush(last: false);
  }

  /// The finished file.
  Uint8List finish() {
    _flush(last: true);
    return _out.takeBytes();
  }

  void _flush({required bool last}) {
    if (_pending.isEmpty && !last) return;
    _page(null, granule: _granule, flags: last ? 0x04 : 0, packets: List.of(_pending));
    _pending.clear();
  }

  void _page(Uint8List? single, {required int granule, int flags = 0, List<Uint8List>? packets}) {
    final all = packets ?? [single!];
    final lacing = <int>[];
    for (final p in all) {
      var left = p.length;
      while (left >= 255) {
        lacing.add(255);
        left -= 255;
      }
      lacing.add(left);
    }
    final bodyLength = all.fold<int>(0, (n, p) => n + p.length);
    final page = ByteData(27 + lacing.length + bodyLength);
    final bytes = page.buffer.asUint8List();
    bytes.setAll(0, 'OggS'.codeUnits);
    page.setUint8(4, 0);
    page.setUint8(5, flags);
    page.setInt64(6, granule, Endian.little);
    page.setUint32(14, _serial, Endian.little);
    page.setUint32(18, _sequence++, Endian.little);
    page.setUint32(22, 0, Endian.little);
    page.setUint8(26, lacing.length);
    bytes.setAll(27, lacing);
    var at = 27 + lacing.length;
    for (final p in all) {
      bytes.setAll(at, p);
      at += p.length;
    }
    page.setUint32(22, _oggCrc(bytes), Endian.little);
    _out.add(bytes);
  }

  static Uint8List _head() {
    final h = ByteData(19);
    final b = h.buffer.asUint8List();
    b.setAll(0, 'OpusHead'.codeUnits);
    h.setUint8(8, 1); // version
    h.setUint8(9, 1); // mono
    h.setUint16(10, opusPreSkip, Endian.little);
    h.setUint32(12, sampleRate, Endian.little);
    h.setInt16(16, 0, Endian.little); // output gain
    h.setUint8(18, 0); // mapping family
    return b;
  }

  static Uint8List _tags() {
    const vendor = 'Frogster';
    final t = ByteData(8 + 4 + vendor.length + 4);
    final b = t.buffer.asUint8List();
    b.setAll(0, 'OpusTags'.codeUnits);
    t.setUint32(8, vendor.length, Endian.little);
    b.setAll(12, vendor.codeUnits);
    t.setUint32(12 + vendor.length, 0, Endian.little);
    return b;
  }
}

/// The audio packets of an Ogg Opus file, and how much of the start to drop.
({List<Uint8List> packets, int preSkip}) readOggOpus(Uint8List data) {
  final packets = <Uint8List>[];
  final partial = BytesBuilder(copy: false);
  var at = 0;
  var serial = -1;
  while (at + 27 <= data.length) {
    final page = ByteData.sublistView(data, at);
    if (String.fromCharCodes(data, at, at + 4) != 'OggS') {
      throw const FormatException('not an Ogg stream');
    }
    final pageSerial = page.getUint32(14, Endian.little);
    if (serial == -1) serial = pageSerial;
    final segments = page.getUint8(26);
    if (at + 27 + segments > data.length) throw const FormatException('truncated Ogg page');
    final lacing = data.sublist(at + 27, at + 27 + segments);
    final bodyLength = lacing.fold<int>(0, (n, l) => n + l);
    final end = at + 27 + segments + bodyLength;
    if (end > data.length) throw const FormatException('truncated Ogg page');
    final pageBytes = Uint8List.sublistView(data, at, end);
    final stored = page.getUint32(22, Endian.little);
    final check = Uint8List.fromList(pageBytes)..setAll(22, const [0, 0, 0, 0]);
    if (_oggCrc(check) != stored) throw const FormatException('damaged Ogg page');
    if (pageSerial == serial) {
      var body = at + 27 + segments;
      for (final l in lacing) {
        partial.add(Uint8List.sublistView(data, body, body + l));
        body += l;
        if (l < 255) packets.add(partial.takeBytes());
      }
    }
    at = end;
  }
  if (packets.length < 2 || String.fromCharCodes(packets[0].take(8)) != 'OpusHead') {
    throw const FormatException('not an Opus stream');
  }
  final head = ByteData.sublistView(packets[0]);
  final preSkip = head.getUint16(10, Endian.little);
  return (packets: packets.sublist(2), preSkip: preSkip);
}

final _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var r = i << 24;
    for (var j = 0; j < 8; j++) {
      r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04c11db7) : (r << 1);
    }
    table[i] = r & 0xffffffff;
  }
  return table;
}();

int _oggCrc(Uint8List bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc = ((crc << 8) ^ _crcTable[((crc >> 24) & 0xff) ^ b]) & 0xffffffff;
  }
  return crc;
}

/// 16-bit mono PCM as a WAV file, which every platform's player takes.
Uint8List pcmToWav(Int16List pcm, {int rate = sampleRate}) {
  final data = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
  final header = ByteData(44);
  void tag(int at, String s) => header.buffer.asUint8List().setAll(at, s.codeUnits);
  tag(0, 'RIFF');
  header.setUint32(4, 36 + data.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, data.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(data))
      .takeBytes();
}
