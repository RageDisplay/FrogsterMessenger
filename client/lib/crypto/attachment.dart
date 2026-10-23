/// Attachment encryption.
///
/// A file is encrypted on the sending device with a fresh AES-256-GCM key
/// before a single byte leaves it. The key travels to recipients inside the
/// Double Ratchet payload of the chat message, so the server stores blobs it
/// cannot read and never learns a file's name, type, or contents.
///
/// Large files are encrypted in independent chunks rather than as one AEAD
/// message: a single-message design would require holding the whole file in
/// memory to authenticate it, which a 100 MiB attachment cannot afford on a
/// phone.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'primitives.dart';

/// Plaintext bytes per chunk.
///
/// Each chunk is encrypted separately, so this bounds peak memory during both
/// encryption and decryption.
const int attachmentChunkSize = 64 * 1024;

/// Largest file the server accepts, mirrored here so the picker can reject an
/// oversized file before spending time encrypting it.
const int maxAttachmentBytes = 100 * 1024 * 1024;

/// Overhead each encrypted chunk adds: a nonce and an authentication tag.
const int attachmentChunkOverhead = aeadNonceLength + aeadTagLength;

/// The key material a recipient needs to decrypt an attachment.
///
/// This travels inside the encrypted chat message, never alongside the blob.
/// Sending it with the upload would hand the server everything it needs.
class AttachmentKey {
  const AttachmentKey({
    required this.blobId,
    required this.key,
    required this.digest,
    required this.size,
    required this.mimeType,
    this.fileName,
  });

  final String blobId;

  /// The 32-byte AES key, used for this attachment only.
  final Uint8List key;

  /// SHA-256 of the complete ciphertext, verified before decryption.
  final Uint8List digest;

  /// Plaintext size in bytes.
  final int size;

  /// The real MIME type. Known only to the participants: the upload declares a
  /// generic hint so the server cannot tell a photo from a document.
  final String mimeType;

  final String? fileName;

  Map<String, dynamic> toJson() => {
        'blob_id': blobId,
        'key': base64Encode(key),
        'digest': base64Encode(digest),
        'size': size,
        'mime': mimeType,
        if (fileName != null) 'name': fileName,
      };

  static AttachmentKey fromJson(Map<String, dynamic> json) => AttachmentKey(
        blobId: json['blob_id'] as String,
        key: base64Decode(json['key'] as String),
        digest: base64Decode(json['digest'] as String),
        size: json['size'] as int,
        mimeType: json['mime'] as String,
        fileName: json['name'] as String?,
      );
}

/// Raised when an attachment fails verification.
class AttachmentException implements Exception {
  const AttachmentException(this.message);
  final String message;

  @override
  String toString() => 'AttachmentException: $message';
}

/// Encrypts a stream of plaintext chunks, yielding ciphertext chunks.
///
/// The caller feeds file chunks in; each is encrypted under the same key with
/// its own random nonce and its index as associated data. Binding the index
/// stops an attacker reordering or dropping chunks: a reordered chunk fails
/// authentication rather than decrypting to plausible-looking data.
class AttachmentEncryptor {
  AttachmentEncryptor._(this.key);

  /// Generates a fresh key for one attachment.
  ///
  /// Never reused across files: a repeated key would let anyone who learns it
  /// from one conversation read attachments from another.
  static Future<AttachmentEncryptor> create() async {
    final keyPair = await generateKeyPair();
    final key = await hkdf(
      inputKeyMaterial: keyPair.privateKey,
      salt: Uint8List(32),
      info: 'Frogster_Attachment_Key'.codeUnits,
    );
    return AttachmentEncryptor._(key);
  }

  /// Rebuilds an encryptor from a known key, for tests and re-uploads.
  static AttachmentEncryptor fromKey(Uint8List key) {
    if (key.length != symmetricKeyLength) {
      throw ArgumentError('attachment key must be $symmetricKeyLength bytes');
    }
    return AttachmentEncryptor._(key);
  }

  final Uint8List key;

  var _index = 0;

  /// Encrypts one plaintext chunk.
  Future<Uint8List> encryptChunk(List<int> plaintext) async {
    final ciphertext = await aeadEncrypt(
      key: key,
      plaintext: plaintext,
      associatedData: _chunkAad(_index),
    );
    _index++;
    return ciphertext.serialize();
  }

  /// Ciphertext size for a given plaintext length.
  static int ciphertextSizeFor(int plaintextSize) {
    if (plaintextSize == 0) return 0;
    final chunks = (plaintextSize + attachmentChunkSize - 1) ~/ attachmentChunkSize;
    return plaintextSize + chunks * attachmentChunkOverhead;
  }
}

/// Decrypts a stream of ciphertext chunks.
class AttachmentDecryptor {
  AttachmentDecryptor(this.key) {
    if (key.length != symmetricKeyLength) {
      throw ArgumentError('attachment key must be $symmetricKeyLength bytes');
    }
  }

  final Uint8List key;
  var _index = 0;

  /// Decrypts one ciphertext chunk.
  ///
  /// Throws when the chunk fails authentication, which covers tampering,
  /// truncation, and reordering alike.
  Future<Uint8List> decryptChunk(Uint8List ciphertext) async {
    try {
      final plaintext = await aeadDecrypt(
        key: key,
        ciphertext: AeadCiphertext.deserialize(ciphertext),
        associatedData: _chunkAad(_index),
      );
      _index++;
      return plaintext;
    } catch (e) {
      throw AttachmentException('chunk $_index failed authentication: $e');
    }
  }
}

/// Verifies a downloaded blob against the digest sent with its key.
///
/// Checked *before* decryption: feeding unverified bytes to the cipher invites
/// chosen-ciphertext games, and a mismatch here means the blob was altered in
/// storage or in transit regardless of what the AEAD would later say.
Future<void> verifyAttachmentDigest({
  required Uint8List ciphertext,
  required Uint8List expectedDigest,
}) async {
  final actual = await sha256(ciphertext);
  if (!constantTimeEquals(actual, expectedDigest)) {
    throw const AttachmentException(
      'ciphertext digest does not match the one in the message; '
      'the blob was modified',
    );
  }
}

/// Associated data binding a chunk to its position in the file.
Uint8List _chunkAad(int index) =>
    Uint8List.fromList(utf8.encode('frogster-attachment-chunk:$index'));

/// Splits plaintext into encrypted chunks and reports the whole-blob digest.
///
/// Convenience for files small enough to hold in memory; a large upload should
/// drive [AttachmentEncryptor] from a file stream instead.
Future<({Uint8List ciphertext, Uint8List digest, Uint8List key})>
    encryptAttachment(Uint8List plaintext) async {
  final encryptor = await AttachmentEncryptor.create();
  // A byte builder, not a List<int>: the latter spends eight bytes per byte,
  // which for a large file is the difference between working and not.
  final parts = BytesBuilder(copy: false);

  for (var offset = 0; offset < plaintext.length; offset += attachmentChunkSize) {
    final end = (offset + attachmentChunkSize).clamp(0, plaintext.length);
    parts.add(await encryptor.encryptChunk(
      Uint8List.sublistView(plaintext, offset, end),
    ));
  }

  final ciphertext = parts.takeBytes();
  return (
    ciphertext: ciphertext,
    digest: await sha256(ciphertext),
    key: encryptor.key,
  );
}

/// Reverses [encryptAttachment], verifying the digest first.
Future<Uint8List> decryptAttachment({
  required Uint8List ciphertext,
  required Uint8List key,
  required Uint8List digest,
}) async {
  await verifyAttachmentDigest(ciphertext: ciphertext, expectedDigest: digest);

  final decryptor = AttachmentDecryptor(key);
  final out = BytesBuilder(copy: false);
  const encryptedChunk = attachmentChunkSize + attachmentChunkOverhead;

  for (var offset = 0; offset < ciphertext.length; offset += encryptedChunk) {
    final end = (offset + encryptedChunk).clamp(0, ciphertext.length);
    out.add(await decryptor.decryptChunk(
      Uint8List.sublistView(ciphertext, offset, end),
    ));
  }
  return out.takeBytes();
}
