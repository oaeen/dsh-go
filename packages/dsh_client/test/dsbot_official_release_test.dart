import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/dsbot_official_v023.json').readAsStringSync()) as Map;
  test('unmodified official v0.2.3 route response adapts via state on mobile hello', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final capturedHello = fixture['hello'] as Map;
    final capturedState = fixture['state'] as Map;
    final endpoints = <String>[];
    server.listen((request) async {
      expect(request.uri.path, '/api/bot');
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final endpoint = body['endpoint'] as String;
      endpoints.add(endpoint);
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(endpoint == 'state' ? capturedState : capturedHello['body']));
      await request.response.close();
    });
    final api = DsBotApi(DsBotHttpTransport(DshConnection(Uri.parse('http://127.0.0.1:${server.port}'))));
    addTearDown(() async {
      await api.close();
      await server.close(force: true);
    });
    final hello = await api.hello();
    expect(hello.compatible, isTrue);
    expect(hello.pluginVersion, 'official');
    expect(endpoints, ['hello', 'state']);
    final state = await api.state();
    expect(state.team!.bots.single.name, 'Chief');
    expect(endpoints, ['hello', 'state']);
  });
  test('official route exists but legacy feed has no mobile boot or API contract', () {
    expect(fixture['registeredRoutes'], containsAll(['/api/bot', '/api/bot/feed']));
    final feed = fixture['feed'] as Map;
    expect(feed['status'], 200);
    final line = (feed['firstChunk'] as String).split('\n').firstWhere((line) => line.startsWith('data: '));
    final hello = jsonDecode(line.substring(6)) as Map;
    expect(hello['revision'], isA<int>());
    expect(hello.containsKey('api'), false);
    expect(hello.containsKey('boot'), false);
  });
}
