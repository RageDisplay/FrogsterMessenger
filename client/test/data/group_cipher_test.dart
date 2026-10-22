/// Which sender keys and group messages a device accepts.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/ratchet/sender_key.dart';
import 'package:frogster/data/local/dao/session_dao.dart';
import 'package:frogster/data/local/database.dart';
import 'package:frogster/data/repositories/group_cipher.dart';

void main() {
  late Directory dir;
  late AppDatabase aliceDb, bobDb;
  late GroupCipher alice, bob;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('frogster_groups');
    aliceDb = await AppDatabase.open(path: '${dir.path}/a.db');
    bobDb = await AppDatabase.open(path: '${dir.path}/b.db');
    alice = GroupCipher(dao: SenderKeyDao(aliceDb.db), selfDeviceId: 'alice-dev');
    bob = GroupCipher(dao: SenderKeyDao(bobDb.db), selfDeviceId: 'bob-dev');
  });
  tearDown(() async {
    await aliceDb.close();
    await bobDb.close();
    await dir.delete(recursive: true);
  });

  Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

  Future<void> share(int epoch) async => bob.install(
        await alice.distribution('g', epoch),
        chatId: 'g',
        fromDeviceId: 'alice-dev',
      );

  Future<String> read(Uint8List sealed, {int chatEpoch = 0}) async => utf8.decode(
        await bob.decrypt(
          chatId: 'g',
          chatEpoch: chatEpoch,
          senderDeviceId: 'alice-dev',
          serialized: sealed,
        ),
      );

  test('a member reads what another sends', () async {
    await share(0);
    expect(await read(await alice.encrypt('g', 0, text('привет'))), 'привет');
  });

  // The pairwise session proves which device a key came from. A key that
  // claims another device would let one member sign as someone else.
  test('a sender key must come from the device it names', () async {
    final skdm = await alice.distribution('g', 0);
    await expectLater(
      bob.install(skdm, chatId: 'g', fromDeviceId: 'mallory-dev'),
      throwsA(isA<SenderKeyException>()),
    );
    await expectLater(
      bob.install(skdm, chatId: 'other-group', fromDeviceId: 'alice-dev'),
      throwsA(isA<SenderKeyException>()),
    );
  });

  test('our own key cannot be replaced from outside', () async {
    final forged = await alice.distribution('g', 0);
    final mine = GroupCipher(dao: SenderKeyDao(bobDb.db), selfDeviceId: 'alice-dev');
    await expectLater(
      mine.install(forged, chatId: 'g', fromDeviceId: 'alice-dev'),
      throwsA(isA<SenderKeyException>()),
    );
  });

  test('a message must come from the device that signed it', () async {
    await share(0);
    final sealed = await alice.encrypt('g', 0, text('x'));
    await expectLater(
      bob.decrypt(chatId: 'g', chatEpoch: 0, senderDeviceId: 'mallory-dev', serialized: sealed),
      throwsA(isA<SenderKeyException>()),
    );
  });

  test('the current and the previous epoch are read, nothing older or newer', () async {
    await share(0);
    final atZero = await alice.encrypt('g', 0, text('в полёте'));
    await share(1);
    final atOne = await alice.encrypt('g', 1, text('сейчас'));

    // Sent just before a membership change, arriving just after it.
    expect(await read(atZero, chatEpoch: 1), 'в полёте');
    expect(await read(atOne, chatEpoch: 1), 'сейчас');

    await share(2);
    final atTwo = await alice.encrypt('g', 2, text('потом'));
    await share(3);
    final stale = await alice.encrypt('g', 2, text('ещё'));
    await expectLater(read(stale, chatEpoch: 4), throwsA(isA<SenderKeyException>()));
    await expectLater(read(atTwo, chatEpoch: 1), throwsA(isA<SenderKeyException>()),
        reason: 'a future epoch is refused until the chat is known to be there');
  });

  test('a message without its key waits rather than failing for good', () async {
    // The key is sent before the message, but the message overtakes it.
    final skdm = await alice.distribution('g', 0);
    final sealed = await alice.encrypt('g', 0, text('рано'));
    await expectLater(read(sealed), throwsA(isA<MissingSenderKeyException>()));
    await bob.install(skdm, chatId: 'g', fromDeviceId: 'alice-dev');
    expect(await read(sealed), 'рано');
  });

  test('a new epoch gets a new key', () async {
    final zero = await alice.ownKey('g', 0);
    final one = await alice.ownKey('g', 1);
    expect(one.chainKey, isNot(zero.chainKey));
    expect(await alice.unshared('g', 1, ['bob-dev', 'alice-dev']), ['bob-dev']);
    await alice.recordShares('g', 1, ['bob-dev']);
    expect(await alice.unshared('g', 1, ['bob-dev', 'carol-dev']), ['carol-dev']);
  });
}
