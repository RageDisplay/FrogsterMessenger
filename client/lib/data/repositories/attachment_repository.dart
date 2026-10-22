/// Uploads and fetches attachments.
///
/// Sits between the UI and [FileClient], translating between the crypto
/// layer's [AttachmentKey] and the data layer's [AttachmentPayload] so neither
/// side has to know about the other's types.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/attachment.dart';
import '../models/models.dart';
import '../remote/file_client.dart';

class AttachmentRepository {
  const AttachmentRepository(this._files);

  final FileClient _files;

  /// Encrypts and uploads a file, returning the reference to put inside the
  /// encrypted chat message.
  Future<AttachmentPayload> upload({
    required Uint8List bytes,
    required String mimeType,
    String? fileName,
    void Function(TransferProgress)? onProgress,
  }) async {
    final key = await _files.upload(
      plaintext: bytes,
      mimeType: mimeType,
      fileName: fileName,
      onProgress: onProgress,
    );

    return AttachmentPayload(
      blobId: key.blobId,
      key: base64Encode(key.key),
      digest: base64Encode(key.digest),
      size: key.size,
      mimeType: key.mimeType,
      fileName: key.fileName,
    );
  }

  /// Downloads and decrypts an attachment.
  ///
  /// The digest is verified before decryption inside [FileClient], so a blob
  /// altered in storage or in transit fails here rather than producing
  /// plausible-looking garbage.
  Future<Uint8List> download(
    AttachmentPayload attachment, {
    void Function(TransferProgress)? onProgress,
  }) {
    return _files.download(
      AttachmentKey(
        blobId: attachment.blobId,
        key: base64Decode(attachment.key),
        digest: base64Decode(attachment.digest),
        size: attachment.size,
        mimeType: attachment.mimeType,
        fileName: attachment.fileName,
      ),
      onProgress: onProgress,
    );
  }

  /// Deletes a blob we uploaded.
  Future<bool> delete(String blobId) => _files.delete(blobId);
}
