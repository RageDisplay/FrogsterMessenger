import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/l10n/app_localizations.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/features/chat/widgets/attachment_view.dart';
import 'package:frogster/features/chat/widgets/message_bubble.dart';
import 'package:frogster/ui/theme/app_theme.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

AttachmentPayload payload({
  String mimeType = 'application/pdf',
  String? fileName = 'report.pdf',
  int size = 2048,
}) =>
    AttachmentPayload(
      blobId: 'blob-1',
      key: 'AAAA',
      digest: 'BBBB',
      size: size,
      mimeType: mimeType,
      fileName: fileName,
    );

void main() {
  group('AttachmentView', () {
    testWidgets('idle shows the file name and size', (tester) async {
      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(),
        state: AttachmentState.idle,
        onDownload: () {},
      )));

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('2 KB'), findsOneWidget);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    });

    testWidgets('tapping an idle attachment starts the download',
        (tester) async {
      // Downloads are explicit: fetching automatically would spend the user's
      // data and reveal to an observer which messages carried files.
      var started = false;

      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(),
        state: AttachmentState.idle,
        onDownload: () => started = true,
      )));

      await tester.tap(find.text('report.pdf'));
      await tester.pump();

      expect(started, isTrue);
    });

    testWidgets('downloading shows progress and blocks further taps',
        (tester) async {
      var taps = 0;

      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(),
        state: AttachmentState.downloading,
        progress: 0.45,
        onDownload: () => taps++,
      )));

      expect(find.text('45%'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('45%'));
      await tester.pump();
      expect(taps, 0, reason: 'a download in flight must not restart on tap');
    });

    testWidgets('a failed download surfaces the reason', (tester) async {
      // A digest mismatch means the blob was altered; the user should see that
      // rather than a generic failure.
      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(),
        state: AttachmentState.failed,
        error: 'the blob was modified',
        onDownload: () {},
      )));

      expect(find.text('the blob was modified'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('a failed download can be retried', (tester) async {
      var retried = false;

      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(),
        state: AttachmentState.failed,
        error: 'network error',
        onDownload: () => retried = true,
      )));

      await tester.tap(find.text('report.pdf'));
      await tester.pump();
      expect(retried, isTrue);
    });

    testWidgets('ready state offers to open the file', (tester) async {
      var opened = false;

      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(),
        state: AttachmentState.ready,
        decrypted: Uint8List.fromList([1, 2, 3]),
        onDownload: () {},
        onOpen: () => opened = true,
      )));

      expect(find.textContaining('Tap to open'), findsOneWidget);
      await tester.tap(find.text('report.pdf'));
      await tester.pump();
      expect(opened, isTrue);
    });

    testWidgets('falls back to a type label without a file name',
        (tester) async {
      await tester.pumpWidget(host(AttachmentView(
        attachment: payload(mimeType: 'image/png', fileName: null),
        state: AttachmentState.idle,
        onDownload: () {},
      )));

      expect(find.text('Photo'), findsOneWidget);
    });

    testWidgets('formats sizes readably', (tester) async {
      for (final (bytes, expected) in [
        (512, '512 B'),
        (4096, '4 KB'),
        (5 * 1024 * 1024, '5.0 MB'),
      ]) {
        await tester.pumpWidget(host(AttachmentView(
          attachment: payload(size: bytes),
          state: AttachmentState.idle,
          onDownload: () {},
        )));
        expect(find.text(expected), findsOneWidget);
      }
    });
  });

  group('MessageBubble with attachments', () {
    testWidgets('renders the attachment through the builder', (tester) async {
      await tester.pumpWidget(host(MessageBubble(
        message: Message(
          id: 'm1',
          chatId: 'c1',
          senderId: 'alice',
          senderDeviceId: 'd1',
          body: '',
          sentAt: DateTime(2026, 1, 1, 9, 15),
          isOutgoing: false,
          attachment: payload(),
        ),
        onReact: (_, _) {},
        attachmentBuilder: (a) => Text('ATTACHMENT:${a.fileName}'),
      )));

      expect(find.text('ATTACHMENT:report.pdf'), findsOneWidget);
    });

    testWidgets('an attachment-only message renders no empty text row',
        (tester) async {
      await tester.pumpWidget(host(MessageBubble(
        message: Message(
          id: 'm1',
          chatId: 'c1',
          senderId: 'alice',
          senderDeviceId: 'd1',
          body: '',
          sentAt: DateTime(2026, 1, 1, 9, 15),
          isOutgoing: false,
          attachment: payload(),
        ),
        onReact: (_, _) {},
        attachmentBuilder: (_) => const Text('FILE'),
      )));

      // Only the file widget and the timestamp; no blank body line.
      expect(find.text(''), findsNothing);
      expect(find.text('FILE'), findsOneWidget);
      expect(find.text('09:15'), findsOneWidget);
    });

    testWidgets('shows caption and attachment together', (tester) async {
      await tester.pumpWidget(host(MessageBubble(
        message: Message(
          id: 'm1',
          chatId: 'c1',
          senderId: 'alice',
          senderDeviceId: 'd1',
          body: 'here are the figures',
          sentAt: DateTime(2026, 1, 1, 9, 15),
          isOutgoing: true,
          attachment: payload(),
        ),
        onReact: (_, _) {},
        attachmentBuilder: (_) => const Text('FILE'),
      )));

      expect(find.text('FILE'), findsOneWidget);
      expect(find.text('here are the figures'), findsOneWidget);
    });
  });

  group('AttachmentPayload', () {
    test('round trips through JSON', () {
      final original = payload();
      final decoded = AttachmentPayload.fromJson(original.toJson());

      expect(decoded.blobId, original.blobId);
      expect(decoded.key, original.key);
      expect(decoded.digest, original.digest);
      expect(decoded.mimeType, original.mimeType);
      expect(decoded.fileName, original.fileName);
    });

    test('travels inside the encrypted message payload', () {
      // The key is the whole secret. On the envelope the server could decrypt
      // every attachment it stores; inside the payload it is protected by the
      // Double Ratchet like any other message content.
      final message = MessagePayload(
        body: 'see attached',
        attachment: payload(),
      );

      final encoded = message.encode();
      final decoded = MessagePayload.decode(encoded);

      expect(decoded.hasAttachment, isTrue);
      expect(decoded.attachment!.key, 'AAAA');
      expect(decoded.body, 'see attached');
    });

    test('identifies images for inline display', () {
      expect(payload(mimeType: 'image/png').isImage, isTrue);
      expect(payload(mimeType: 'application/pdf').isImage, isFalse);
    });
  });
}
