import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uni_browser_extension_host/local_app_extension_bridge_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late MemoryLocalAppBridgeStorage storage;
  late LocalAppBridgeHost host;

  LocalAppBridgeHostConfig testConfig({Set<String> trustedIds = const <String>{'transli-webex'}}) {
    return LocalAppBridgeHostConfig(
      appId: 'transli',
      serverName: 'Transli Desktop',
      portStart: 14555,
      portEnd: 14570,
      trustedExtensionIds: trustedIds,
      supportedFeatures: const <String>[
        kLocalAppBridgeFeaturePing,
        kLocalAppBridgeFeatureStatus,
        kLocalAppBridgeFeatureWebsocket,
        kLocalAppBridgeFeatureControlPlaneV2,
        kLocalAppBridgeFeatureAppleOcr,
        kLocalAppBridgeFeatureImageOcr,
      ],
    );
  }

  setUp(() {
    storage = MemoryLocalAppBridgeStorage();
    host = LocalAppBridgeHost(config: testConfig(), storage: storage);
  });

  tearDown(() async {
    await host.resetForTesting();
    host.dispose();
  });

  test('discovers server info on the first free loopback port', () async {
    await host.start();

    expect(host.isInitialized, isTrue);
    expect(host.serverPort, isNotNull);
    expect(host.supportedFeatures, contains(kLocalAppBridgeFeatureAppleOcr));

    final response = await HttpClient().getUrl(
      Uri.parse('http://127.0.0.1:${host.serverPort}/server-info'),
    );
    final httpResponse = await response.close();
    final body = jsonDecode(await utf8.decodeStream(httpResponse)) as Map<String, dynamic>;

    expect(httpResponse.statusCode, HttpStatus.ok);
    expect(body['app_id'], 'transli');
    expect(body['server_name'], 'Transli Desktop');
    expect(body['ws_url'], 'ws://127.0.0.1:${host.serverPort}/ws');
    expect(body['auth_challenge'], isA<String>());
    expect((body['supported_features'] as List<dynamic>), contains('apple_ocr'));
  });

  test('allows chrome-extension CORS on server-info', () async {
    await host.start();
    const origin = 'chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef';
    final request = await HttpClient().getUrl(
      Uri.parse('http://127.0.0.1:${host.serverPort}/server-info'),
    );
    request.headers.set('origin', origin);
    final httpResponse = await request.close();
    await httpResponse.drain<void>();
    expect(httpResponse.statusCode, HttpStatus.ok);
    expect(httpResponse.headers.value('access-control-allow-origin'), origin);
  });

  test('authenticates a registered extension and routes image_ocr', () async {
    host.registerHandler(kLocalAppBridgeMessageImageOcr, (request) async {
      expect(request.data['image_data_url'], 'data:image/png;base64,abc');
      return LocalAppBridgeReply.ok(<String, Object?>{
        'regions': <Map<String, Object?>>[
          <String, Object?>{
            'text': 'Hello',
            'box': <List<int>>[
              <int>[0, 0],
              <int>[10, 0],
              <int>[10, 8],
              <int>[0, 8],
            ],
            'confidence': 0.9,
          },
        ],
      });
    });
    host.authorizeNextPairing();
    await host.start();

    final info = await _readServerInfo(host.serverPort!);
    final socket = await WebSocket.connect(info['ws_url'] as String);
    final replies = _replyQueue(socket);
    addTearDown(() async {
      await replies.close();
      await socket.close();
    });

    final token = 'token-one-token-two';
    final extensionId = 'transli-webex';
    final extensionUuid = '11111111-2222-4333-8444-555555555555';
    final challenge = info['auth_challenge'] as String;
    final hmac = Hmac(sha256, utf8.encode(token));
    final response = hmac.convert(utf8.encode('$challenge:$extensionUuid:$extensionId')).toString();

    final auth = await _roundTrip(socket, replies, <String, Object?>{
      'id': 'auth-1',
      'type': 'auth',
      'data': <String, Object?>{
        'extension_id': extensionId,
        'extension_uuid': extensionUuid,
        'auth_mode': 'register',
        'token': token,
        'response': response,
        'browser_name': 'chrome',
        'name': 'TransliWebEx',
        'version': '1.0.0',
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    expect(auth['success'], isTrue);
    expect((auth['data'] as Map<String, dynamic>)['authenticated'], isTrue);
    expect(host.isConnected, isTrue);

    final ocr = await _roundTrip(socket, replies, <String, Object?>{
      'id': 'ocr-1',
      'type': 'image_ocr',
      'data': <String, Object?>{'image_data_url': 'data:image/png;base64,abc'},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    expect(ocr['success'], isTrue);
    final regions = ((ocr['data'] as Map<String, dynamic>)['regions'] as List<dynamic>);
    expect(regions, isNotEmpty);
    expect((regions.first as Map<String, dynamic>)['text'], 'Hello');
  });

  test('broadcasts events to authenticated clients only', () async {
    host.authorizeNextPairing();
    await host.start();
    final info = await _readServerInfo(host.serverPort!);
    final authenticated = await WebSocket.connect(info['ws_url'] as String);
    final unauthenticated = await WebSocket.connect(info['ws_url'] as String);
    final authReplies = _replyQueue(authenticated);
    final guestReplies = _replyQueue(unauthenticated);
    addTearDown(() async {
      await authReplies.close();
      await guestReplies.close();
      await authenticated.close();
      await unauthenticated.close();
    });

    final token = 'token-one-token-two';
    const extensionId = 'transli-webex';
    const extensionUuid = '11111111-2222-4333-8444-555555555555';
    final hmac = Hmac(sha256, utf8.encode(token));
    final response = hmac
        .convert(
          utf8.encode('${info['auth_challenge']}:$extensionUuid:$extensionId'),
        )
        .toString();
    final auth = await _roundTrip(authenticated, authReplies, <String, Object?>{
      'id': 'auth-broadcast',
      'type': 'auth',
      'data': <String, Object?>{
        'extension_id': extensionId,
        'extension_uuid': extensionUuid,
        'auth_mode': 'register',
        'token': token,
        'response': response,
        'browser_name': 'chrome',
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    expect(auth['success'], isTrue);

    expect(
      host.broadcastToAuthenticatedClients(<String, Object?>{
        'type': 'SYNC_INTERCEPT_CONFIG',
        'id': 'push-1',
        'data': <String, Object?>{'enabled': true},
      }),
      1,
    );
    final pushed = await authReplies.next().timeout(const Duration(seconds: 3));
    expect(pushed['type'], 'SYNC_INTERCEPT_CONFIG');
    await expectLater(
      guestReplies.next().timeout(const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('rejects first registration until pairing is authorized', () async {
    await host.start();
    final info = await _readServerInfo(host.serverPort!);
    final socket = await WebSocket.connect(info['ws_url'] as String);
    final replies = _replyQueue(socket);
    addTearDown(() async {
      await replies.close();
      await socket.close();
    });

    final token = 'token-one-token-two';
    final extensionId = 'transli-webex';
    final extensionUuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    final challenge = info['auth_challenge'] as String;
    final hmac = Hmac(sha256, utf8.encode(token));
    final response = hmac.convert(utf8.encode('$challenge:$extensionUuid:$extensionId')).toString();

    final auth = await _roundTrip(socket, replies, <String, Object?>{
      'id': 'auth-2',
      'type': 'auth',
      'data': <String, Object?>{
        'extension_id': extensionId,
        'extension_uuid': extensionUuid,
        'auth_mode': 'register',
        'token': token,
        'response': response,
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    expect(auth['success'], isFalse);
    expect(auth['error'], 'pairing_authorization_required');
    expect(host.isConnected, isFalse);
  });

  test('keeps authorizeNextPairing valid without a pairing-code deadline', () async {
    host.authorizeNextPairing();
    await host.start();
    final info = await _readServerInfo(host.serverPort!);
    final socket = await WebSocket.connect(info['ws_url'] as String);
    final replies = _replyQueue(socket);
    addTearDown(() async {
      await replies.close();
      await socket.close();
    });

    const token = 'token-one-token-two';
    const extensionId = 'transli-webex';
    const extensionUuid = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
    final challenge = info['auth_challenge'] as String;
    final hmac = Hmac(sha256, utf8.encode(token));
    final response = hmac.convert(utf8.encode('$challenge:$extensionUuid:$extensionId')).toString();

    final auth = await _roundTrip(socket, replies, <String, Object?>{
      'id': 'auth-open',
      'type': 'auth',
      'data': <String, Object?>{
        'extension_id': extensionId,
        'extension_uuid': extensionUuid,
        'auth_mode': 'register',
        'token': token,
        'response': response,
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    expect(auth['success'], isTrue);
    expect((auth['data'] as Map<String, dynamic>)['authenticated'], isTrue);
  });

  test('authenticates after server-info is fetched with a chrome-extension Origin', () async {
    host.authorizeNextPairing();
    await host.start();

    final request = await HttpClient().getUrl(
      Uri.parse('http://127.0.0.1:${host.serverPort}/server-info'),
    );
    request.headers.set('origin', 'chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef');
    final httpResponse = await request.close();
    final info = jsonDecode(await utf8.decodeStream(httpResponse)) as Map<String, dynamic>;

    final socket = await WebSocket.connect(
      info['ws_url'] as String,
      headers: <String, dynamic>{
        'Origin': 'chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef',
      },
    );
    final replies = _replyQueue(socket);
    addTearDown(() async {
      await replies.close();
      await socket.close();
    });

    const token = 'token-one-token-two';
    const extensionId = 'abcdefghijklmnopqrstuvwxyzabcdef';
    const extensionUuid = '11111111-2222-4333-8444-555555555555';
    final challenge = info['auth_challenge'] as String;
    final hmac = Hmac(sha256, utf8.encode(token));
    final response = hmac.convert(utf8.encode('$challenge:$extensionUuid:$extensionId')).toString();

    final auth = await _roundTrip(socket, replies, <String, Object?>{
      'id': 'auth-origin',
      'type': 'auth',
      'data': <String, Object?>{
        'extension_id': extensionId,
        'extension_uuid': extensionUuid,
        'auth_mode': 'register',
        'token': token,
        'response': response,
        'browser_name': 'chrome',
        'name': 'TransliWebEx',
        'version': '1.0.0',
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    expect(auth['success'], isTrue);
    expect((auth['data'] as Map<String, dynamic>)['authenticated'], isTrue);
  });

  test('accepts a chrome-extension origin and rejects a web origin', () async {
    host.authorizeNextPairing();
    await host.start();
    final info = await _readServerInfo(host.serverPort!);
    final wsUrl = info['ws_url'] as String;
    const chromeOrigin = 'chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef';

    final accepted = await WebSocket.connect(
      wsUrl,
      headers: <String, dynamic>{'Origin': chromeOrigin},
    );
    addTearDown(accepted.close);
    expect(accepted.readyState, WebSocket.open);

    await expectLater(
      WebSocket.connect(
        wsUrl,
        headers: <String, dynamic>{'Origin': 'https://evil.example'},
      ),
      throwsA(isA<Object>()),
    );
  });
}

Future<Map<String, dynamic>> _readServerInfo(int port) async {
  final request = await HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/server-info'));
  final response = await request.close();
  return jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
}

class _ReplyQueue {
  _ReplyQueue(WebSocket socket) {
    socket.listen((raw) {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      add(jsonDecode(text) as Map<String, dynamic>);
    });
  }

  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
  final List<Completer<Map<String, dynamic>>> _waiters = <Completer<Map<String, dynamic>>>[];

  void add(Map<String, dynamic> value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
      return;
    }
    _buffer.add(value);
  }

  Future<Map<String, dynamic>> next() {
    if (_buffer.isNotEmpty) {
      return Future<Map<String, dynamic>>.value(_buffer.removeAt(0));
    }
    final completer = Completer<Map<String, dynamic>>();
    _waiters.add(completer);
    return completer.future;
  }

  Future<void> close() async {}
}

_ReplyQueue _replyQueue(WebSocket socket) => _ReplyQueue(socket);

Future<Map<String, dynamic>> _roundTrip(
  WebSocket socket,
  _ReplyQueue replies,
  Map<String, Object?> message,
) async {
  socket.add(jsonEncode(message));
  return replies.next().timeout(const Duration(seconds: 3));
}
