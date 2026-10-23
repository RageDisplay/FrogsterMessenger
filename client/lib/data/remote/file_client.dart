/// Uploads and downloads encrypted attachments over gRPC.
///
/// Encryption happens here, before the first byte reaches the network: the
/// server only ever sees ciphertext, a size, and a digest. The key that opens
/// it travels separately, inside the chat message's Double Ratchet payload.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import '../../crypto/attachment.dart';
import '../repositories/attachment_repository.dart' show BlobTransport;
import 'gen/frogster/v1/file.pbgrpc.dart' as pb;
import 'server_config.dart';

/// Progress of a transfer, for the UI to render.
class TransferProgress {
  const TransferProgress({required this.bytes, required this.total});

  final int bytes;
  final int total;

  double get fraction => total == 0 ? 0 : bytes / total;
}

/// Raised when a transfer fails.
class FileTransferException implements Exception {
  const FileTransferException(this.message);
  final String message;

  @override
  String toString() => 'FileTransferException: $message';
}

class FileClient implements BlobTransport {
  FileClient({required ServerConfig server})
      : _channel = ClientChannel(
          server.fileHost,
          port: server.filePort,
          options: ChannelOptions(
            // Plaintext only for a development server. Through the
            // installer's proxy this is TLS on the main port; without it the
            // ciphertext is still safe, but the bearer token is not.
            credentials: server.isSecure
                ? ChannelCredentials.secure(
                    certificates: server.caCertificatePem == null
                        ? null
                        : utf8.encode(server.caCertificatePem!),
                  )
                : const ChannelCredentials.insecure(),
          ),
        ) {
    _stub = pb.FileTransferClient(_channel);
  }

  final ClientChannel _channel;
  late final pb.FileTransferClient _stub;

  /// Supplies a current access token for each call. A token captured once
  /// at sign-in would expire a quarter of an hour later and break every
  /// transfer after that.
  Future<String> Function()? accessToken;

  CallOptions get _callOptions => CallOptions(
        providers: [
          (metadata, _) async {
            final provider = accessToken;
            if (provider != null) {
              metadata['authorization'] = 'Bearer ${await provider()}';
            }
          },
        ],
        timeout: const Duration(minutes: 10),
      );

  /// Encrypts [plaintext] and uploads it, returning everything a recipient
  /// needs to fetch and open it.
  ///
  /// The returned [AttachmentKey] must be sent inside the encrypted chat
  /// message. Attaching it to the upload instead would hand the server the key
  /// to every file it stores.
  @override
  Future<AttachmentKey> upload({
    required Uint8List plaintext,
    required String mimeType,
    String? fileName,
    void Function(TransferProgress)? onProgress,
    void Function(Uint8List ciphertext)? onSealed,
  }) async {
    final sealed = await encryptAttachment(plaintext);
    final ciphertext = sealed.ciphertext;
    onSealed?.call(ciphertext);

    // A generator rather than a controller: gRPC pulls the next chunk only
    // when the transport has room for it, so progress follows what has
    // actually gone out instead of what was queued.
    Stream<pb.UploadRequest> requests() async* {
      // The init message declares size and digest up front so the server can
      // reject an oversized upload before streaming it.
      yield pb.UploadRequest(
        init: pb.UploadInit(
          totalSize: Int64(ciphertext.length),
          // Deliberately generic: the real MIME type stays inside the
          // encrypted message, so the server cannot tell a photo from a
          // document.
          contentHint: 'attachment',
          digest: sealed.digest,
        ),
      );
      // Chunked so a large file costs one buffer rather than its whole size
      // in memory on either side.
      for (var offset = 0; offset < ciphertext.length; offset += _chunkSize) {
        final end = (offset + _chunkSize).clamp(0, ciphertext.length);
        yield pb.UploadRequest(
          chunk: Uint8List.sublistView(ciphertext, offset, end),
        );
        onProgress?.call(TransferProgress(bytes: end, total: ciphertext.length));
      }
    }

    try {
      final response = await _stub.upload(requests(), options: _callOptions);

      return AttachmentKey(
        blobId: response.blobId,
        key: sealed.key,
        digest: sealed.digest,
        size: plaintext.length,
        mimeType: mimeType,
        fileName: fileName,
      );
    } on GrpcError catch (e) {
      throw FileTransferException(_describe(e));
    }
  }

  /// Downloads a blob and decrypts it.
  ///
  /// The digest is verified before decryption, so a blob altered in storage or
  /// in transit is rejected rather than fed to the cipher.
  Future<Uint8List> download(
    AttachmentKey attachment, {
    void Function(TransferProgress)? onProgress,
  }) async {
    final ciphertext =
        await downloadCiphertext(attachment.blobId, onProgress: onProgress);
    return decryptAttachment(
      ciphertext: ciphertext,
      key: attachment.key,
      digest: attachment.digest,
    );
  }

  /// Fetches a blob as stored: still encrypted, unverified.
  @override
  Future<Uint8List> downloadCiphertext(
    String blobId, {
    void Function(TransferProgress)? onProgress,
  }) async {
    final parts = BytesBuilder(copy: false);

    try {
      final stream = _stub.download(
        pb.DownloadRequest(blobId: blobId),
        options: _callOptions,
      );

      await for (final chunk in stream) {
        parts.add(chunk.chunk);
        onProgress?.call(TransferProgress(
          bytes: parts.length,
          total: chunk.totalSize.toInt(),
        ));
      }
    } on GrpcError catch (e) {
      throw FileTransferException(_describe(e));
    }
    return parts.takeBytes();
  }

  /// Deletes a blob we uploaded.
  @override
  Future<bool> delete(String blobId) async {
    try {
      final response = await _stub.delete(
        pb.DeleteRequest(blobId: blobId),
        options: _callOptions,
      );
      return response.deleted;
    } on GrpcError catch (e) {
      throw FileTransferException(_describe(e));
    }
  }

  Future<void> shutdown() => _channel.shutdown();

  /// Turns a gRPC status into something a user can act on.
  String _describe(GrpcError error) => switch (error.code) {
        StatusCode.unauthenticated => 'Session expired; sign in again',
        StatusCode.resourceExhausted => 'Upload limit reached; try later',
        StatusCode.invalidArgument =>
          error.message ?? 'The server rejected the file',
        StatusCode.notFound => 'This attachment is no longer available',
        _ => 'Transfer failed: ${error.message ?? error.code}',
      };

  /// Ciphertext bytes per gRPC message.
  static const int _chunkSize = 64 * 1024;
}
