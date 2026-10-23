/// Choosing files to send, and handing received ones to the platform.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../../crypto/attachment.dart';

/// A file chosen by the user, before encryption.
class PickedAttachment {
  const PickedAttachment({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    this.width,
    this.height,
    this.voice = false,
    this.durationMs,
    this.waveform,
  });

  final Uint8List bytes;
  final String mimeType;
  final String fileName;

  /// Pixel size, for images.
  final int? width;
  final int? height;

  /// A voice message recorded in the app.
  final bool voice;
  final int? durationMs;
  final String? waveform;

  bool get isImage => mimeType.startsWith('image/');
}

/// Where a file comes from.
enum AttachSource {
  /// Photos and videos.
  gallery,

  /// A new photo. Phones only.
  camera,

  /// Any file at all.
  file,
}

/// Why nothing was picked although the user chose something.
class PickRejected implements Exception {
  const PickRejected.tooLarge(this.fileName);

  final String fileName;
}

/// Opens the platform's pickers.
class AttachmentPicker {
  const AttachmentPicker();

  /// The camera exists as a source on phones only; on a PC the file dialog
  /// is the way in.
  static bool get hasCamera => Platform.isAndroid || Platform.isIOS;

  /// Photos are scaled down the way other messengers do it: a 12-megapixel
  /// original is ten times the bytes for no visible gain on a phone screen.
  /// "File" sends the original, untouched.
  static const _photoMaxSide = 2560.0;
  static const _photoQuality = 85;

  /// Lets the user choose; an empty list when they cancel.
  ///
  /// Throws [PickRejected] for a file over the size limit, after the others
  /// are read: one oversized video does not cancel a whole album.
  Future<List<PickedAttachment>> pick(AttachSource source) async {
    final picked = <PickedAttachment>[];
    final rejected = <String>[];

    Future<void> add(String name, Future<int> Function() length,
        Future<Uint8List> Function() read, {String? mime}) async {
      if (await length() > maxAttachmentBytes) {
        rejected.add(name);
        return;
      }
      picked.add(await describe(name, await read(), mimeType: mime));
    }

    switch (source) {
      case AttachSource.gallery:
        if (Platform.isAndroid || Platform.isIOS) {
          final media = await ImagePicker().pickMultipleMedia(
            maxWidth: _photoMaxSide,
            maxHeight: _photoMaxSide,
            imageQuality: _photoQuality,
          );
          for (final file in media) {
            await add(file.name, file.length, file.readAsBytes, mime: file.mimeType);
          }
        } else {
          final files = await FilePicker.pickFiles(type: FileType.media);
          for (final file in files) {
            await add(file.name, () async => await file.length() ?? 0, file.readAsBytes);
          }
        }
      case AttachSource.camera:
        final photo = await ImagePicker().pickImage(
          source: ImageSource.camera,
          maxWidth: _photoMaxSide,
          maxHeight: _photoMaxSide,
          imageQuality: _photoQuality,
        );
        if (photo != null) {
          await add(photo.name, photo.length, photo.readAsBytes, mime: photo.mimeType);
        }
      case AttachSource.file:
        final files = await FilePicker.pickFiles();
        for (final file in files) {
          await add(file.name, () async => await file.length() ?? 0, file.readAsBytes);
        }
    }

    if (rejected.isNotEmpty && picked.isEmpty) {
      throw PickRejected.tooLarge(rejected.first);
    }
    return picked;
  }

  /// Wraps bytes from anywhere -- a picker, a paste, a drop -- with their
  /// type and, for an image, its size.
  static Future<PickedAttachment> describe(
    String fileName,
    Uint8List bytes, {
    String? mimeType,
  }) async {
    final mime = mimeType ?? mimeTypeFor(fileName);
    int? width;
    int? height;
    if (mime.startsWith('image/')) {
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        width = descriptor.width;
        height = descriptor.height;
        descriptor.dispose();
        buffer.dispose();
      } catch (_) {
        // Not an image the engine can read; it goes as a plain file.
      }
    }
    return PickedAttachment(
      bytes: bytes,
      mimeType: width == null && mime.startsWith('image/') ? 'application/octet-stream' : mime,
      fileName: fileName,
      width: width,
      height: height,
    );
  }

  /// Maps a file name to a MIME type.
  ///
  /// The real type stays inside the encrypted payload; the upload always
  /// declares a generic hint, so this never reaches the server.
  static String mimeTypeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final extension = dot == -1 ? '' : fileName.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'bmp' => 'image/bmp',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'ogg' || 'opus' => 'audio/ogg',
      'wav' => 'audio/wav',
      'txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }
}

/// Where a received file went.
enum SaveOutcome { saved, opened, cancelled }

/// Hands decrypted files to the platform.
class AttachmentSaver {
  const AttachmentSaver();

  /// Asks where to keep the file and writes it there.
  Future<SaveOutcome> save(String fileName, Uint8List bytes, String mimeType) async {
    final where = await FilePicker.saveFile(
      fileName: safeFileName(fileName),
      bytes: bytes,
      mimeType: mimeType,
    );
    return where == null ? SaveOutcome.cancelled : SaveOutcome.saved;
  }

  /// Opens the file in the program the system has for it.
  ///
  /// On Windows that takes a real file, written to the temporary folder: the
  /// plaintext touches disk there and nowhere else. Android has no such
  /// hand-off without an extra plugin, so a phone saves instead, and so does
  /// anything Windows would run rather than open: a received program is
  /// saved, never started with one click.
  Future<SaveOutcome> open(String fileName, Uint8List bytes, String mimeType) async {
    final name = safeFileName(fileName);
    if (!Platform.isWindows || isExecutable(name)) return save(name, bytes, mimeType);
    final dir = await Directory.systemTemp.createTemp('frogster');
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    // Explorer opens a path with its associated program and, unlike cmd,
    // parses nothing in it: a name with `&` in it stays a name.
    await Process.start('explorer.exe', [file.path]);
    return SaveOutcome.opened;
  }

  /// A file name arrives from the other side of the conversation: nothing in
  /// it may name a directory or mean something to a shell.
  static String safeFileName(String name) {
    final base = name
        .split(RegExp(r'[\\/]'))
        .last
        .replaceAll(RegExp(r'[<>:"|?*&^%!\x00-\x1F]'), '_')
        .trim();
    // Windows drops trailing dots and spaces, which can turn "a.exe." into
    // "a.exe" after any check made on the name.
    final cleaned = base.replaceAll(RegExp(r'[. ]+$'), '');
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  /// Types Windows executes instead of opening.
  static bool isExecutable(String name) {
    final dot = name.lastIndexOf('.');
    if (dot == -1) return false;
    return _executable.contains(name.substring(dot + 1).toLowerCase());
  }

  static const _executable = {
    'exe', 'com', 'bat', 'cmd', 'msi', 'msp', 'scr', 'pif', 'cpl', 'dll',
    'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'hta', 'jar',
    'lnk', 'url', 'reg', 'inf', 'scf', 'appref-ms', 'msc', 'application',
    'gadget', 'iso', 'img', 'vhd', 'vhdx', 'library-ms', 'settingcontent-ms',
  };
}
