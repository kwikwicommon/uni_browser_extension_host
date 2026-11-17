import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uni_browser_extension_host/src/native_messaging/codec.dart';
import 'package:uni_browser_extension_host/src/native_messaging/state.dart';
import 'package:uni_browser_extension_host/src/protocol.dart';

typedef LocalAppBridgeServerInfoFetcher = Future<Map<String, Object?>> Function(int port);

class LocalAppBridgeNativeMessagingStdioHost {
  LocalAppBridgeNativeMessagingStdioHost({
    required this.stateFile,
    LocalAppBridgeServerInfoFetcher? fetchServerInfo,
    DateTime Function()? clock,
  }) : _fetchServerInfo = fetchServerInfo ?? _defaultFetchServerInfo,
       _clock = clock ?? DateTime.now;

  final File stateFile;
  final LocalAppBridgeServerInfoFetcher _fetchServerInfo;
  final DateTime Function() _clock;

  Future<Map<String, Object?>> handle(Map<String, dynamic> message) async {
    final type = message['type']?.toString() ?? '';
    final id = message['id']?.toString() ?? '';
    final reply = await _dispatch(type);
    return <String, Object?>{
      if (id.isNotEmpty) 'id': id,
      'success': reply['success'] == true,
      'data': reply['data'] ?? const <String, Object?>{},
      if (reply['error'] != null) 'error': reply['error'],
      'timestamp': _clock().toUtc().toIso8601String(),
    };
  }

  Future<void> run({
    Stream<List<int>>? input,
    void Function(List<int> bytes)? output,
  }) async {
    final reader = LocalAppBridgeNativeMessagingReader();
    final stream = input ?? stdin;
    await for (final chunk in stream) {
      for (final message in reader.add(chunk)) {
        final reply = LocalAppBridgeNativeMessagingCodec.encode(await handle(message));
        if (output != null) {
          output(reply);
        } else {
          stdout.add(reply);
          await stdout.flush();
        }
      }
    }
  }

  Future<Map<String, Object?>> _dispatch(String type) async {
    switch (type) {
      case kLocalAppBridgeMessagePing:
        return <String, Object?>{
          'success': true,
          'data': <String, Object?>{'status': 'ok'},
        };
      case kLocalAppBridgeMessageServerInfo:
      case 'SERVER_INFO':
        return _serverInfoReply();
      default:
        return <String, Object?>{
          'success': false,
          'error': 'unsupported_message',
          'data': const <String, Object?>{},
        };
    }
  }

  Future<Map<String, Object?>> _serverInfoReply() async {
    final state = await readLocalAppBridgeNativeHostState(stateFile);
    final port = state?.port;
    if (state == null || !state.running || port == null) {
      return <String, Object?>{
        'success': false,
        'error': 'app_not_running',
        'data': const <String, Object?>{},
      };
    }
    try {
      final info = await _fetchServerInfo(port);
      return <String, Object?>{'success': true, 'data': info};
    } catch (error) {
      return <String, Object?>{
        'success': false,
        'error': 'server_info_unavailable',
        'data': <String, Object?>{'detail': error.toString()},
      };
    }
  }
}

Future<Map<String, Object?>> _defaultFetchServerInfo(int port) async {
  final request = await HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/server-info'));
  final response = await request.close();
  final decoded = jsonDecode(await utf8.decodeStream(response));
  if (decoded is! Map) {
    throw const FormatException('server-info must be a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}
