/// Voice messages: the player shared by every bubble, and the bubble itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/audio/voice_player.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/repositories/message_repository.dart';
import 'package:frogster/features/chat/widgets/voice_message_view.dart';
import 'package:frogster/l10n/app_localizations.dart';
import 'package:frogster/ui/theme/app_theme.dart';

/// The speakers, recorded instead of heard.
class FakeOutput implements VoiceOutput {
  final position = StreamController<Duration>.broadcast(sync: true);
  final duration = StreamController<Duration>.broadcast(sync: true);
  final complete = StreamController<void>.broadcast(sync: true);
  final calls = <String>[];
  final played = <Int16List>[];
  Duration? seekedTo;

  @override
  Stream<Duration> get onPosition => position.stream;
  @override
  Stream<Duration> get onDuration => duration.stream;
  @override
  Stream<void> get onComplete => complete.stream;
  @override
  Future<void> play(Int16List pcm) async {
    calls.add('play');
    played.add(pcm);
  }

  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration to) async => seekedTo = to;
  @override
  Future<void> dispose() async {}
}

Uint8List bytes(int tag) => Uint8List.fromList([tag, tag, tag]);

void main() {
  late FakeOutput out;
  late VoicePlayer player;
  late int decodes;

  setUp(() {
    out = FakeOutput();
    decodes = 0;
    player = VoicePlayer(
      output: out,
      decode: (ogg) async {
        decodes++;
        return Int16List.fromList([...ogg, 0xFF]); // "decoded"
      },
    );
  });

  group('the voice player', () {
    test('plays, pauses and resumes where it stopped', () async {
      var fetches = 0;
      Future<Uint8List> load() async {
        fetches++;
        return bytes(1);
      }

      await player.toggle('a', load);
      expect(player.isPlaying('a'), isTrue);
      expect(out.played.single, [1, 1, 1, 0xFF], reason: 'what is played is the decoded sound');

      out.duration.add(const Duration(seconds: 4));
      out.position.add(const Duration(seconds: 1));
      expect(player.progressOf('a'), 0.25);

      await player.toggle('a', load);
      expect(player.isPlaying('a'), isFalse);
      expect(out.calls.last, 'pause');

      await player.toggle('a', load);
      expect(player.isPlaying('a'), isTrue);
      expect(out.calls.last, 'resume');
      expect(fetches, 1);
    });

    test('starting another message stops the first', () async {
      await player.toggle('a', () async => bytes(1));
      out.duration.add(const Duration(seconds: 4));
      out.position.add(const Duration(seconds: 2));

      await player.toggle('b', () async => bytes(2));
      expect(player.isPlaying('a'), isFalse);
      expect(player.isPlaying('b'), isTrue);
      out.duration.add(const Duration(seconds: 4));
      out.position.add(const Duration(seconds: 1));
      expect(player.progressOf('b'), 0.25);
      expect(player.progressOf('a'), 0, reason: 'only the one playing shows progress');
      expect(out.played.last, [2, 2, 2, 0xFF]);
    });

    test('a message still loading is not shown as playing', () async {
      await player.toggle('a', () async => bytes(1));
      final gate = Completer<Uint8List>();
      final switching = player.toggle('b', () => gate.future);
      await Future<void>.delayed(Duration.zero);
      expect(player.isLoading('b'), isTrue);
      expect(player.isPlaying('b'), isFalse);
      expect(out.calls.last, 'stop', reason: 'the first one is silent while the next one loads');
      gate.complete(bytes(2));
      await switching;
      expect(player.isPlaying('b'), isTrue);
    });

    test('a message replayed is not fetched or decoded again', () async {
      var fetches = 0;
      Future<Uint8List> load() async {
        fetches++;
        return bytes(1);
      }

      await player.toggle('a', load);
      out.complete.add(null);
      expect(player.isPlaying('a'), isFalse);
      await player.toggle('a', load);
      expect(player.isPlaying('a'), isTrue);
      expect((fetches, decodes), (1, 1));
    });

    test('the message that ends goes back to the start', () async {
      await player.toggle('a', () async => bytes(1));
      out.duration.add(const Duration(seconds: 3));
      out.position.add(const Duration(seconds: 3));
      out.complete.add(null);
      expect(player.isPlaying('a'), isFalse);
      expect(player.positionOf('a'), Duration.zero);
    });

    test('seeking moves only the message playing', () async {
      await player.toggle('a', () async => bytes(1));
      out.duration.add(const Duration(seconds: 10));

      await player.seek('b', 0.5);
      expect(out.seekedTo, isNull);
      await player.seek('a', 0.5);
      expect(out.seekedTo, const Duration(seconds: 5));
    });

    test('a failed fetch leaves nothing stuck loading', () async {
      await expectLater(player.toggle('a', () async => throw Exception('offline')), throwsException);
      expect(player.isLoading('a'), isFalse);
      expect(player.isPlaying('a'), isFalse);
      await player.toggle('a', () async => bytes(1));
      expect(player.isPlaying('a'), isTrue);
    });
  });

  test('a voice message keeps its length and waveform on the way, and says so in the chat list', () {
    final wave = base64Encode(List.generate(64, (i) => i * 4));
    final placeholder = AttachmentPayload.uploading(
      messageId: 'm1', size: 900, mimeType: 'audio/ogg', fileName: 'voice.ogg',
      voice: true, durationMs: 7300, waveform: wave,
    );
    final sent = placeholder.copyWith(blobId: 'blob1', key: 'k', digest: 'd');
    final received = AttachmentPayload.fromJson(jsonDecode(jsonEncode(sent.toJson())) as Map<String, dynamic>);

    expect(received.voice, isTrue);
    expect(received.durationMs, 7300);
    expect(received.waveform, wave);
    expect(MessageRepository.previewOf('', received), PreviewTokens.voice);

    final song = AttachmentPayload.fromJson({...sent.toJson()..remove('voice')});
    expect(song.voice, isFalse, reason: 'an audio file sent as a file stays a file');
    expect(MessageRepository.previewOf('', song), isNot(PreviewTokens.voice));
  });

  testWidgets('the bubble shows the length, plays on tap and turns into pause', (tester) async {
    const attachment = AttachmentPayload(
      blobId: 'blob1', key: 'k', digest: 'd', size: 900, mimeType: 'audio/ogg',
      voice: true, durationMs: 67000,
    );
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: VoiceMessageView(
            attachment: attachment,
            player: player,
            load: () async {
              loads++;
              return bytes(1);
            },
          ),
        ),
      ),
    ));

    expect(find.text('1:07'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.byTooltip('Pause'), findsOneWidget);

    out.duration.add(const Duration(seconds: 67));
    out.position.add(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('0:05'), findsOneWidget, reason: 'counts the time played while playing');

    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  testWidgets('a voice message still going up cannot be played yet', (tester) async {
    final attachment = AttachmentPayload.uploading(
      messageId: 'm1', size: 900, mimeType: 'audio/ogg', voice: true, durationMs: 2000,
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: VoiceMessageView(attachment: attachment, player: player, load: () async => bytes(1), uploadProgress: 0.4),
      ),
    ));
    expect(find.byType(IconButton), findsNothing);
    final spinner = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(spinner.value, 0.4);
  });
}
