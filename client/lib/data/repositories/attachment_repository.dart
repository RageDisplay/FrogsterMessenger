/// Uploads and fetches attachments.
///
/// Sits between the UI and [FileClient], translating between the crypto
/// layer's [AttachmentKey] and the data layer's [AttachmentPayload] so neither
/// side has to know about the other's types.
///
/// Fetched files are kept twice over, so that scrolling back through a chat
/// does not download its photos again:
/// - on disk, as the ciphertext the server holds: no plaintext lands there,
///   and the key stays in the message that referenced it;
/// - in memory, decrypted, for the files most recently shown.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../crypto/attachment.dart';
import '../models/models.dart';
import '../remote/file_client.dart';

/// Moves blobs to and from the attachment server.
///
/// [FileClient] in the app; a fake in tests.
abstract interface class BlobTransport {
  Future<AttachmentKey> upload({
    required Uint8List plaintext,
    required String mimeType,
    String? fileName,
    void Function(TransferProgress)? onProgress,
    void Function(Uint8List ciphertext)? onSealed,
  });

  Future<Uint8List> downloadCiphertext(
    String blobId, {
    void Function(TransferProgress)? onProgress,
  });

  Future<bool> delete(String blobId);
}

class AttachmentRepository {
  AttachmentRepository(
    this._files, {
    Directory? cacheDir,
    this.memoryBudget = 96 * 1024 * 1024,
    this.diskBudget = 512 * 1024 * 1024,
  }) : _cacheDir = cacheDir;

  final BlobTransport _files;
  final Directory? _cacheDir;

  /// Decrypted bytes kept in memory, at most.
  final int memoryBudget;

  /// Ciphertext kept on disk, at most. The oldest files go first.
  final int diskBudget;

  final _memory = <String, Uint8List>{}; // insertion-ordered: LRU
  var _memoryBytes = 0;

  /// Downloads in flight, so two bubbles showing one photo fetch it once.
  final _inFlight = <String, Future<Uint8List>>{};

  /// Encrypts and uploads a file, returning the reference to put inside the
  /// encrypted chat message.
  Future<AttachmentPayload> upload({
    required Uint8List bytes,
    required String mimeType,
    String? fileName,
    void Function(TransferProgress)? onProgress,
  }) async {
    Uint8List? sealed;
    final key = await _files.upload(
      plaintext: bytes,
      mimeType: mimeType,
      fileName: fileName,
      onProgress: onProgress,
      onSealed: (ciphertext) => sealed = ciphertext,
    );

    // The sender has the file already: showing it in their own bubble must
    // not cost a download.
    _remember(key.blobId, bytes);
    final ciphertext = sealed;
    if (ciphertext != null) unawaited(_store(key.blobId, ciphertext));

    return AttachmentPayload(
      blobId: key.blobId,
      key: base64Encode(key.key),
      digest: base64Encode(key.digest),
      size: key.size,
      mimeType: key.mimeType,
      fileName: key.fileName,
    );
  }

  /// Uploads the file behind an [AttachmentPayload.uploading] placeholder
  /// and returns the placeholder completed: everything it described, plus
  /// where the file now is and the key to it.
  Future<AttachmentPayload> uploadAs(
    AttachmentPayload placeholder,
    Uint8List bytes, {
    void Function(TransferProgress)? onProgress,
  }) async {
    final uploaded = await upload(
      bytes: bytes,
      mimeType: placeholder.mimeType,
      fileName: placeholder.fileName,
      onProgress: onProgress,
    );
    _memoryBytes -= _memory.remove(placeholder.blobId)?.length ?? 0;
    return placeholder.copyWith(
      blobId: uploaded.blobId,
      key: uploaded.key,
      digest: uploaded.digest,
    );
  }

  /// Makes a file being sent from here showable before it is uploaded.
  void preload(String blobId, Uint8List bytes) => _remember(blobId, bytes);

  /// The decrypted file, if it can be had without the network.
  Uint8List? cached(String blobId) {
    final bytes = _memory.remove(blobId);
    if (bytes != null) _memory[blobId] = bytes; // most recently used
    return bytes;
  }

  /// Downloads and decrypts an attachment.
  ///
  /// The digest is verified before decryption, so a blob altered in storage
  /// or in transit fails here rather than producing plausible-looking
  /// garbage. That holds for the disk cache too: a cached file is checked
  /// exactly like a downloaded one.
  Future<Uint8List> download(
    AttachmentPayload attachment, {
    void Function(TransferProgress)? onProgress,
  }) {
    final hit = cached(attachment.blobId);
    if (hit != null) return Future.value(hit);
    // Still on its way up from here: there is nothing to fetch yet.
    if (attachment.isUploading) {
      return Future.error(StateError('attachment is still uploading'));
    }
    // A block body, not an arrow: remove() returns this very future, and
    // whenComplete would wait for it -- that is, for itself.
    return _inFlight[attachment.blobId] ??= _fetch(attachment, onProgress).whenComplete(() {
      _inFlight.remove(attachment.blobId);
    });
  }

  Future<Uint8List> _fetch(
    AttachmentPayload attachment,
    void Function(TransferProgress)? onProgress,
  ) async {
    final key = base64Decode(attachment.key);
    final digest = base64Decode(attachment.digest);

    final stored = await _load(attachment.blobId);
    if (stored != null) {
      try {
        final bytes = await decryptAttachment(ciphertext: stored, key: key, digest: digest);
        _remember(attachment.blobId, bytes);
        return bytes;
      } on AttachmentException {
        // A damaged cache file: drop it and fetch a good copy.
        await _forget(attachment.blobId);
      }
    }

    final ciphertext =
        await _files.downloadCiphertext(attachment.blobId, onProgress: onProgress);
    final bytes = await decryptAttachment(ciphertext: ciphertext, key: key, digest: digest);
    _remember(attachment.blobId, bytes);
    unawaited(_store(attachment.blobId, ciphertext));
    return bytes;
  }

  /// Deletes a blob we uploaded.
  Future<bool> delete(String blobId) async {
    _memoryBytes -= _memory.remove(blobId)?.length ?? 0;
    await _forget(blobId);
    return _files.delete(blobId);
  }

  void _remember(String blobId, Uint8List bytes) {
    // One huge video is not worth evicting every photo for.
    if (bytes.length > memoryBudget ~/ 4) return;
    _memoryBytes -= _memory.remove(blobId)?.length ?? 0;
    _memory[blobId] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > memoryBudget && _memory.isNotEmpty) {
      final oldest = _memory.keys.first;
      _memoryBytes -= _memory.remove(oldest)!.length;
    }
  }

  /// Blob ids come from other people's messages; only a plain id names a
  /// file, so nothing can point outside the cache directory.
  static final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  File? _fileFor(String blobId) {
    final dir = _cacheDir;
    if (dir == null || !_safeId.hasMatch(blobId)) return null;
    return File('${dir.path}${Platform.pathSeparator}$blobId');
  }

  Future<Uint8List?> _load(String blobId) async {
    final file = _fileFor(blobId);
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      // Touched, so the size limit evicts what has not been looked at.
      unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _store(String blobId, Uint8List ciphertext) async {
    final file = _fileFor(blobId);
    if (file == null || ciphertext.length > diskBudget ~/ 4) return;
    try {
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsBytes(ciphertext, flush: true);
      await part.rename(file.path);
      await _trim();
    } on FileSystemException {
      // A cache that cannot be written is only a slower cache.
    }
  }

  Future<void> _forget(String blobId) async {
    try {
      await _fileFor(blobId)?.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<void> _trim() async {
    final dir = _cacheDir;
    if (dir == null) return;
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final entry in dir.list()) {
      if (entry is! File || entry.path.endsWith('.part')) continue;
      final stat = await entry.stat();
      files.add((entry, stat));
      total += stat.size;
    }
    if (total <= diskBudget) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in files) {
      if (total <= diskBudget) break;
      try {
        await file.delete();
        total -= stat.size;
      } on FileSystemException {
        // In use or already gone.
      }
    }
  }

  /// Empties both caches, on sign-out.
  Future<void> clear() async {
    _memory.clear();
    _memoryBytes = 0;
    final dir = _cacheDir;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }
}
