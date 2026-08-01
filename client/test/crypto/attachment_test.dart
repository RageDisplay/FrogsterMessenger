import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/attachment.dart';

Uint8List randomBytes(int n) {
  final rng = Random(42); // deterministic, so failures reproduce
  return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
}

void main() {
  group('round trip', () {
    test('small file', () async {
      final plaintext = Uint8List.fromList(utf8.encode('a short document'));
      final sealed = await encryptAttachment(plaintext);

      final back = await decryptAttachment(
        ciphertext: sealed.ciphertext,
        key: sealed.key,
        digest: sealed.digest,
      );

      expect(back, equals(plaintext));
    });

    test('empty file', () async {
      final sealed = await encryptAttachment(Uint8List(0));
      final back = await decryptAttachment(
        ciphertext: sealed.ciphertext,
        key: sealed.key,
        digest: sealed.digest,
      );

      expect(back, isEmpty);
    });

    test('file spanning several chunks', () async {
      // Deliberately not a chunk multiple, so the final partial chunk is
      // exercised too.
      final plaintext = randomBytes(attachmentChunkSize * 3 + 1234);
      final sealed = await encryptAttachment(plaintext);

      final back = await decryptAttachment(
        ciphertext: sealed.ciphertext,
        key: sealed.key,
        digest: sealed.digest,
      );

      expect(back.length, plaintext.length);
      expect(back, equals(plaintext));
    });

    test('exact chunk boundary', () async {
      final plaintext = randomBytes(attachmentChunkSize * 2);
      final sealed = await encryptAttachment(plaintext);

      final back = await decryptAttachment(
        ciphertext: sealed.ciphertext,
        key: sealed.key,
        digest: sealed.digest,
      );

      expect(back, equals(plaintext));
    });
  });

  group('confidentiality', () {
    test('ciphertext does not contain the plaintext', () async {
      const marker = 'CONFIDENTIAL_DOCUMENT_CONTENTS';
      final plaintext = Uint8List.fromList(utf8.encode(marker * 20));
      final sealed = await encryptAttachment(plaintext);

      // Search the raw bytes: the server stores exactly these.
      final rendered = latin1.decode(sealed.ciphertext, allowInvalid: true);
      expect(rendered.contains(marker), isFalse,
          reason: 'the uploaded bytes must reveal nothing about the file');
    });

    test('each attachment gets a fresh key', () async {
      final plaintext = Uint8List.fromList(utf8.encode('same file twice'));

      final first = await encryptAttachment(plaintext);
      final second = await encryptAttachment(plaintext);

      expect(first.key, isNot(equals(second.key)),
          reason: 'a reused key would let one leaked key open other files');
      expect(first.ciphertext, isNot(equals(second.ciphertext)),
          reason: 'identical ciphertext would reveal that the same file was '
              'uploaded twice');
    });

    test('the wrong key cannot decrypt', () async {
      final plaintext = Uint8List.fromList(utf8.encode('secret'));
      final sealed = await encryptAttachment(plaintext);
      final otherKey = Uint8List.fromList(List.filled(32, 9));

      expect(
        () => decryptAttachment(
          ciphertext: sealed.ciphertext,
          key: otherKey,
          digest: sealed.digest,
        ),
        throwsA(isA<AttachmentException>()),
      );
    });
  });

  group('integrity', () {
    test('a tampered byte is rejected by the digest', () async {
      final plaintext = randomBytes(1000);
      final sealed = await encryptAttachment(plaintext);

      final tampered = Uint8List.fromList(sealed.ciphertext)..[10] ^= 0xFF;

      expect(
        () => decryptAttachment(
          ciphertext: tampered,
          key: sealed.key,
          digest: sealed.digest,
        ),
        throwsA(isA<AttachmentException>()),
        reason: 'the digest is checked before the cipher sees the bytes',
      );
    });

    test('truncation is rejected', () async {
      final plaintext = randomBytes(attachmentChunkSize * 2);
      final sealed = await encryptAttachment(plaintext);

      final truncated = Uint8List.sublistView(
        sealed.ciphertext,
        0,
        sealed.ciphertext.length - 100,
      );

      expect(
        () => decryptAttachment(
          ciphertext: truncated,
          key: sealed.key,
          digest: sealed.digest,
        ),
        throwsA(isA<AttachmentException>()),
      );
    });

    test('a wrong digest is rejected even for intact ciphertext', () async {
      final sealed = await encryptAttachment(randomBytes(500));

      expect(
        () => verifyAttachmentDigest(
          ciphertext: sealed.ciphertext,
          expectedDigest: Uint8List.fromList(List.filled(32, 0)),
        ),
        throwsA(isA<AttachmentException>()),
      );
    });

    test('reordered chunks fail authentication', () async {
      // Each chunk is bound to its index, so swapping two must not decrypt to
      // plausible-looking data with the pieces rearranged.
      final encryptor = AttachmentEncryptor.fromKey(
        Uint8List.fromList(List.filled(32, 5)),
      );
      final chunkA = await encryptor.encryptChunk(utf8.encode('first chunk'));
      final chunkB = await encryptor.encryptChunk(utf8.encode('second chunk'));

      final decryptor = AttachmentDecryptor(
        Uint8List.fromList(List.filled(32, 5)),
      );

      // Feeding chunk B where chunk A belongs must fail.
      expect(
        () => decryptor.decryptChunk(chunkB),
        throwsA(isA<AttachmentException>()),
      );

      // In the right order it works.
      final fresh = AttachmentDecryptor(
        Uint8List.fromList(List.filled(32, 5)),
      );
      expect(utf8.decode(await fresh.decryptChunk(chunkA)), 'first chunk');
      expect(utf8.decode(await fresh.decryptChunk(chunkB)), 'second chunk');
    });
  });

  group('AttachmentKey wire format', () {
    test('round trips through JSON', () {
      final key = AttachmentKey(
        blobId: 'blob-1',
        key: Uint8List.fromList(List.filled(32, 3)),
        digest: Uint8List.fromList(List.filled(32, 7)),
        size: 4096,
        mimeType: 'image/webp',
        fileName: 'holiday.webp',
      );

      final decoded = AttachmentKey.fromJson(
        jsonDecode(jsonEncode(key.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.blobId, 'blob-1');
      expect(decoded.key, equals(key.key));
      expect(decoded.digest, equals(key.digest));
      expect(decoded.size, 4096);
      expect(decoded.mimeType, 'image/webp');
      expect(decoded.fileName, 'holiday.webp');
    });

    test('carries the real MIME type, which the upload never declares', () {
      // The server is told a generic hint; the true type is part of the
      // end-to-end encrypted payload.
      final key = AttachmentKey(
        blobId: 'b',
        key: Uint8List(32),
        digest: Uint8List(32),
        size: 1,
        mimeType: 'application/pdf',
      );

      expect(key.toJson()['mime'], 'application/pdf');
    });
  });

  group('size accounting', () {
    test('predicts ciphertext size', () async {
      for (final size in [0, 1, 100, attachmentChunkSize,
        attachmentChunkSize + 1, attachmentChunkSize * 3 + 77]) {
        final sealed = await encryptAttachment(randomBytes(size));
        expect(
          sealed.ciphertext.length,
          AttachmentEncryptor.ciphertextSizeFor(size),
          reason: 'size prediction is wrong for a $size byte file; uploads '
              'declare this up front so the server can reject oversized ones',
        );
      }
    });
  });
}
