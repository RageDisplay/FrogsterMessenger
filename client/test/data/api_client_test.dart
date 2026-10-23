/// The REST client on the wire.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/remote/api_client.dart';
import 'package:frogster/data/remote/server_config.dart';

void main() {
  test('a Russian title reaches the server as UTF-8 JSON', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <String>[];
    server.listen((request) async {
      bodies.add(await utf8.decoder.bind(request).join());
      request.response
        ..statusCode = 204
        ..close();
    });
    final api = ApiClient(server: ServerConfig(baseUri: Uri.parse('http://127.0.0.1:${server.port}')));
    try {
      await api.renameVoiceChannel('chat', 'channel', 'Болталка 🐸');
      expect(jsonDecode(bodies.single), {'name': 'Болталка 🐸'});
    } finally {
      api.close();
      await server.close(force: true);
    }
  });
}
