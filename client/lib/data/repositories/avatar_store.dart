/// Profile and group pictures: fetched once per version, kept on disk.
///
/// Avatars are not secret -- any signed-in user can fetch anyone's -- so the
/// disk copy is the picture itself, under the app's private data folder.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Whose picture.
enum AvatarOwner { user, chat }

/// Fetches pictures from the server; the API client in the app.
typedef AvatarFetch = Future<Uint8List?> Function(AvatarOwner owner, String id);

class AvatarStore {
  AvatarStore({required AvatarFetch fetch, Directory? cacheDir})
      : _fetch = fetch,
        _dir = cacheDir;

  final AvatarFetch _fetch;
  final Directory? _dir;

  /// One notifier per owner, shared by every widget showing them.
  final _watched = <String, _Watched>{};

  static String _key(AvatarOwner owner, String id) => '${owner.name}_$id';

  /// The picture of [id] at [version], loading it if needed. Null while it
  /// loads, and for good when there is none: a version of zero or below.
  ValueListenable<Uint8List?> watch(AvatarOwner owner, String id, int version) {
    final key = _key(owner, id);
    final watched = _watched.putIfAbsent(key, () => _Watched());
    if (version <= 0) {
      if (watched.version != version) {
        watched.version = version;
        watched.value.value = null;
        unawaited(_dropFiles(key));
      }
      return watched.value;
    }
    if (watched.version != version) {
      watched.version = version;
      unawaited(_load(owner, id, version, watched));
    }
    return watched.value;
  }

  /// Puts a picture we just uploaded in place, so it shows without a round
  /// trip.
  Future<void> put(AvatarOwner owner, String id, int version, Uint8List image) async {
    final key = _key(owner, id);
    final watched = _watched.putIfAbsent(key, () => _Watched());
    watched.version = version;
    watched.value.value = image;
    await _write(key, version, image);
  }

  Future<void> _load(AvatarOwner owner, String id, int version, _Watched watched) async {
    final key = _key(owner, id);
    final file = _file(key, version);
    try {
      if (file != null && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (watched.version == version) watched.value.value = bytes;
        return;
      }
    } on FileSystemException {
      // Fall through to the network.
    }
    try {
      final bytes = await _fetch(owner, id);
      // A newer version may have been asked for meanwhile.
      if (watched.version != version) return;
      watched.value.value = bytes;
      if (bytes != null) await _write(key, version, bytes);
    } catch (_) {
      // Shown without a picture; asked for again on the next version.
      if (watched.version == version) watched.version = 0;
    }
  }

  File? _file(String key, int version) {
    final dir = _dir;
    if (dir == null || !RegExp(r'^[a-z]+_[A-Za-z0-9-]{1,64}$').hasMatch(key)) return null;
    return File('${dir.path}${Platform.pathSeparator}${key}_$version');
  }

  Future<void> _write(String key, int version, Uint8List bytes) async {
    final file = _file(key, version);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await _dropFiles(key);
      await file.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      // Only a slower cache.
    }
  }

  /// Older versions of an owner's picture.
  Future<void> _dropFiles(String key) async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return;
    await for (final entry in dir.list()) {
      final name = entry.uri.pathSegments.last;
      if (entry is File && name.startsWith('${key}_')) {
        try {
          await entry.delete();
        } on FileSystemException {
          // In use; replaced next time.
        }
      }
    }
  }

  Future<void> clear() async {
    for (final w in _watched.values) {
      w.value.value = null;
      w.version = 0;
    }
    final dir = _dir;
    if (dir != null && await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    }
  }
}

class _Watched {
  int version = 0;
  final value = ValueNotifier<Uint8List?>(null);
}

/// The side of an avatar, in pixels: sharp at the largest size the app
/// shows one, small enough to fetch in a blink.
const int avatarPixels = 512;

/// Turns any picture into an avatar: the centre square, scaled down, as a
/// JPEG. Runs off the UI thread; a 12-megapixel photo takes a moment.
Future<Uint8List> prepareAvatar(Uint8List picture) => compute(_prepare, picture);

Uint8List _prepare(Uint8List picture) {
  final decoded = img.decodeImage(picture);
  if (decoded == null) throw const FormatException('not a picture');
  // Phones store how the camera was held instead of turning the pixels.
  final upright = img.bakeOrientation(decoded);
  final square = img.copyResizeCropSquare(upright, size: avatarPixels, interpolation: img.Interpolation.average);
  return img.encodeJpg(square, quality: 85);
}
