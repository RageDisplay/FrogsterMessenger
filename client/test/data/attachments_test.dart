/// Sending files: shown at once, uploaded, then sent; and fetched files kept
/// so a chat does not download its photos twice.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/attachment.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/file_client.dart';
import 'package:frogster/data/repositories/attachment_repository.dart';

import 'fake_server.dart';

/// The attachment server, in memory.
class FakeBlobs implements BlobTransport {
  final blobs = <String, Uint8List>{};
  var downloads = 0;
  var failNextUpload = false;

  /// Holds uploads until completed, to look at what happens meanwhile.
  Completer<void>? gate;

  @override
  Future<AttachmentKey> upload({
    required Uint8List plaintext,
    required String mimeType,
    String? fileName,
    void Function(TransferProgress)? onProgress,
    void Function(Uint8List ciphertext)? onSealed,
  }) async {
    final sealed = await encryptAttachment(plaintext);
    onSealed?.call(sealed.ciphertext);
    onProgress?.call(TransferProgress(bytes: sealed.ciphertext.length ~/ 2, total: sealed.ciphertext.length));
    await gate?.future;
    if (failNextUpload) {
      failNextUpload = false;
      throw const FileTransferException('connection lost');
    }
    final id = 'blob${blobs.length + 1}';
    blobs[id] = sealed.ciphertext;
    onProgress?.call(TransferProgress(bytes: sealed.ciphertext.length, total: sealed.ciphertext.length));
    return AttachmentKey(
      blobId: id,
      key: sealed.key,
      digest: sealed.digest,
      size: plaintext.length,
      mimeType: mimeType,
      fileName: fileName,
    );
  }

  @override
  Future<Uint8List> downloadCiphertext(String blobId, {void Function(TransferProgress)? onProgress}) async {
    downloads++;
    final blob = blobs[blobId];
    if (blob == null) throw const FileTransferException('This attachment is no longer available');
    return blob;
  }

  @override
  Future<bool> delete(String blobId) async => blobs.remove(blobId) != null;
}

Uint8List bytesOf(int n, [int seed = 1]) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));
}

void main() {
  late FakeServer server;
  late FakeDevice alice, bob;
  late FakeChat cloud, secret;
  late FakeBlobs blobs;
  late AttachmentRepository aliceFiles, bobFiles;
  late Directory cacheDir;

  setUp(() async {
    server = FakeServer();
    alice = await server.addDevice('alice');
    bob = await server.addDevice('bob');
    cloud = server.createChat(type: 'direct', mode: ChatMode.cloud, creator: alice.user, members: [bob.user]);
    secret = server.createChat(type: 'direct', mode: ChatMode.secret, creator: alice.user, members: [bob.user]);
    for (final d in [alice, bob]) {
      await d.ws.connect();
    }
    await server.settle();
    blobs = FakeBlobs();
    cacheDir = await Directory.systemTemp.createTemp('frogster-blobs');
    aliceFiles = AttachmentRepository(blobs);
    bobFiles = AttachmentRepository(blobs, cacheDir: cacheDir);
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    // Cache writes run behind the downloads; let them land first.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      await cacheDir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file; the temp folder is cleaned anyway.
    }
  });

  /// Sends [bytes] the way the chat screen does.
  Future<Message> sendFile(FakeDevice from, AttachmentRepository files, String chatId, Uint8List bytes,
      {String body = '', String name = 'photo.jpg', String mime = 'image/jpeg'}) {
    late AttachmentPayload placeholder;
    return from.repository.sendFile(
      chatId: chatId,
      body: body,
      placeholder: (id) {
        placeholder = AttachmentPayload.uploading(
          messageId: id, size: bytes.length, mimeType: mime, fileName: name, width: 1600, height: 1200,
        );
        files.preload(placeholder.blobId, bytes);
        return placeholder;
      },
      upload: (onProgress) => files.uploadAs(placeholder, bytes, onProgress: (p) => onProgress(p.fraction)),
    );
  }

  test('a file shows at once, goes up, then reaches the other side intact', () async {
    for (final chat in [cloud, secret]) {
      final photo = bytesOf(150 * 1024, chat.id.hashCode);
      blobs.gate = Completer();
      final progress = <double>[];
      final sub = alice.repository.uploadProgress.listen((p) => progress.add(p.fraction));

      final sent = await sendFile(alice, aliceFiles, chat.id, photo, body: 'смотри');
      // Shown before a byte is up, with the photo itself to show.
      final shown = (await alice.messages(chat.id)).last;
      expect(shown.id, sent.id);
      expect(shown.attachment!.isUploading, isTrue);
      expect(aliceFiles.cached(shown.attachment!.blobId), photo);
      await server.settle();
      expect(await bob.messages(chat.id), isEmpty, reason: 'nothing goes out before the upload');

      blobs.gate!.complete();
      await alice.repository.uploadsSettled;
      await server.settle();
      await sub.cancel();
      expect(progress, isNotEmpty);
      expect(progress.last, 1);

      final received = (await bob.messages(chat.id)).single;
      expect(received.body, 'смотри');
      final attachment = received.attachment!;
      expect(attachment.isUploading, isFalse);
      expect((attachment.width, attachment.height), (1600, 1200));
      expect(await bobFiles.download(attachment), photo);
    }
  });

  test('an album arrives in order, the caption with the first file', () async {
    for (var i = 0; i < 3; i++) {
      await sendFile(alice, aliceFiles, cloud.id, bytesOf(1000 + i, i), body: i == 0 ? 'отпуск' : '', name: 'p$i.jpg');
    }
    await alice.repository.uploadsSettled;
    await server.settle();
    final received = await bob.messages(cloud.id);
    expect(received.map((m) => m.attachment!.fileName), ['p0.jpg', 'p1.jpg', 'p2.jpg']);
    expect(received.map((m) => m.body), ['отпуск', '', '']);
  });

  test('a failed upload is retried without picking the file again', () async {
    blobs.failNextUpload = true;
    final sent = await sendFile(alice, aliceFiles, cloud.id, bytesOf(2048));
    await alice.repository.uploadsSettled;
    final failed = (await alice.messages(cloud.id)).single;
    expect(failed.status, MessageStatus.failed);
    expect(alice.repository.canRetry(failed), isTrue);

    await alice.repository.retry(failed);
    await alice.repository.uploadsSettled;
    await server.settle();
    expect((await bob.messages(cloud.id)).single.id, sent.id);
    expect((await alice.messages(cloud.id)).single.status, isNot(MessageStatus.failed));
  });

  test('a file deleted while it uploads is never sent', () async {
    blobs.gate = Completer();
    final started = alice.repository.uploadProgress.first;
    final sent = await sendFile(alice, aliceFiles, cloud.id, bytesOf(4096));
    await started; // the upload is under way, not just queued
    await alice.repository.delete((await alice.messages(cloud.id)).single);
    blobs.gate!.complete();
    await alice.repository.uploadsSettled;
    await server.settle();
    expect(await bob.messages(cloud.id), isEmpty);
    expect(await alice.dao.messageById(sent.id), isNull);
  });

  // The file is not kept anywhere: an upload the app was closed in the
  // middle of cannot be finished, and must not wait forever as "sending".
  test('an upload cut off by closing the app becomes failed, nothing else does', () async {
    final now = DateTime.now();
    Message pending(String id, AttachmentPayload? attachment) => Message(
          id: id, chatId: cloud.id, senderId: alice.user.id, senderDeviceId: alice.id, body: '',
          sentAt: now, isOutgoing: true, status: MessageStatus.pending, attachment: attachment,
        );
    await alice.dao.upsertMessage(pending('cut', AttachmentPayload.uploading(messageId: 'cut', size: 1, mimeType: 'image/png')));
    await alice.dao.upsertMessage(pending('text', null));
    await alice.dao.upsertMessage(pending('uploaded', const AttachmentPayload(
      blobId: 'blob9', key: 'k', digest: 'd', size: 1, mimeType: 'image/png',
    )));

    expect(await alice.dao.failInterruptedUploads(), 1);
    expect((await alice.dao.messageById('cut'))!.status, MessageStatus.failed);
    expect((await alice.dao.messageById('text'))!.status, MessageStatus.pending);
    expect((await alice.dao.messageById('uploaded'))!.status, MessageStatus.pending);
    expect(alice.repository.canRetry((await alice.dao.messageById('cut'))!), isFalse);
  });

  group('the attachment cache', () {
    Future<AttachmentPayload> uploaded(Uint8List bytes) =>
        AttachmentRepository(blobs).upload(bytes: bytes, mimeType: 'image/png', fileName: 'a.png');

    test('a fetched file comes from disk the next time, still encrypted there', () async {
      final photo = bytesOf(10000);
      final attachment = await uploaded(photo);

      expect(await bobFiles.download(attachment), photo);
      expect(blobs.downloads, 1);

      // A new start: memory is empty, the disk is not.
      final restarted = AttachmentRepository(blobs, cacheDir: cacheDir);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await restarted.download(attachment), photo);
      expect(blobs.downloads, 1);

      final onDisk = await File('${cacheDir.path}${Platform.pathSeparator}${attachment.blobId}').readAsBytes();
      expect(onDisk, blobs.blobs[attachment.blobId], reason: 'the ciphertext, not the photo');
    });

    test('a damaged cache file is replaced by a good copy', () async {
      final photo = bytesOf(5000);
      final attachment = await uploaded(photo);
      await bobFiles.download(attachment);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final file = File('${cacheDir.path}${Platform.pathSeparator}${attachment.blobId}');
      final damaged = await file.readAsBytes();
      damaged[100] ^= 0xFF;
      await file.writeAsBytes(damaged);

      final restarted = AttachmentRepository(blobs, cacheDir: cacheDir);
      expect(await restarted.download(attachment), photo);
      expect(blobs.downloads, 2);
    });

    test('a blob id from a message never names a path outside the cache', () async {
      final photo = bytesOf(300);
      final good = await uploaded(photo);
      final hostile = AttachmentPayload(
        blobId: '..${Platform.pathSeparator}escape-${cacheDir.path.hashCode}',
        key: good.key, digest: good.digest, size: good.size, mimeType: good.mimeType,
      );
      blobs.blobs[hostile.blobId] = blobs.blobs[good.blobId]!;
      expect(await bobFiles.download(hostile), photo);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await File('${cacheDir.parent.path}${Platform.pathSeparator}escape-${cacheDir.path.hashCode}').exists(), isFalse);
      expect(await cacheDir.list().toList(), isEmpty);
    });

    test('memory keeps the most recently shown files within its budget', () async {
      final files = AttachmentRepository(blobs, memoryBudget: 40 * 1024);
      final payloads = [for (var i = 0; i < 5; i++) await uploaded(bytesOf(9 * 1024, i))];
      for (final p in payloads) {
        await files.download(p);
      }
      expect(files.cached(payloads.first.blobId), isNull, reason: 'the oldest went first');
      expect(files.cached(payloads.last.blobId), isNotNull);
    });

    test('two bubbles showing one photo fetch it once', () async {
      final attachment = await uploaded(bytesOf(2000));
      await Future.wait([bobFiles.download(attachment), bobFiles.download(attachment)]);
      expect(blobs.downloads, 1);
    });
  });
}
