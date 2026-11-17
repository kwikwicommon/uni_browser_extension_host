import 'dart:convert';
import 'dart:io';

import 'package:uni_browser_extension_host/src/protocol.dart';

class LocalAppBridgeNativeHostState {
  const LocalAppBridgeNativeHostState({
    required this.running,
    required this.appId,
    required this.serverName,
    required this.protocolVersion,
    this.port,
    this.wsUrl,
    this.nativeHostName,
    this.supportedFeatures = const <String>[],
    this.updatedAt,
  });

  final bool running;
  final String appId;
  final String serverName;
  final String protocolVersion;
  final int? port;
  final String? wsUrl;
  final String? nativeHostName;
  final List<String> supportedFeatures;
  final DateTime? updatedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'running': running,
      'app_id': appId,
      'appId': appId,
      'server_name': serverName,
      'serverName': serverName,
      'protocol_version': protocolVersion,
      'protocolVersion': protocolVersion,
      'port': port,
      'ws_url': wsUrl,
      'wsUrl': wsUrl,
      'native_host_name': nativeHostName ?? defaultLocalAppBridgeNativeHostName(appId),
      'nativeHostName': nativeHostName ?? defaultLocalAppBridgeNativeHostName(appId),
      'supported_features': supportedFeatures,
      'supportedFeatures': supportedFeatures,
      'updated_at': (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
    };
  }

  factory LocalAppBridgeNativeHostState.fromJson(Map<String, dynamic> json) {
    return LocalAppBridgeNativeHostState(
      running: json['running'] == true,
      appId: json['app_id']?.toString() ?? json['appId']?.toString() ?? '',
      serverName: json['server_name']?.toString() ?? json['serverName']?.toString() ?? '',
      protocolVersion:
          json['protocol_version']?.toString() ?? json['protocolVersion']?.toString() ?? '',
      port: json['port'] is int ? json['port'] as int : int.tryParse('${json['port']}'),
      wsUrl: json['ws_url']?.toString() ?? json['wsUrl']?.toString(),
      nativeHostName: json['native_host_name']?.toString() ?? json['nativeHostName']?.toString(),
      supportedFeatures: _stringList(json['supported_features'] ?? json['supportedFeatures']),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.map((item) => item.toString()).where((item) => item.isNotEmpty).toList();
}

String resolveUnsandboxedHome({String? home}) {
  final current = home ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  const marker = '/Library/Containers/';
  final index = current.indexOf(marker);
  if (index > 0) {
    return current.substring(0, index);
  }
  return current;
}

String defaultLocalAppBridgeNativeHostStatePath(String appId, {String? home}) {
  final resolvedHome = resolveUnsandboxedHome(home: home);
  if (resolvedHome.isEmpty) {
    return 'extension-bridge/native-host-state.json';
  }
  if (Platform.isMacOS) {
    return '$resolvedHome/Library/Application Support/$appId/extension-bridge/native-host-state.json';
  }
  if (Platform.isWindows) {
    final appData =
        Platform.environment['APPDATA'] ?? '$resolvedHome/AppData/Roaming';
    return '$appData\\$appId\\extension-bridge\\native-host-state.json';
  }
  return '$resolvedHome/.local/share/$appId/extension-bridge/native-host-state.json';
}

File localAppBridgeNativeHostStateFile(String appId, {String? path, String? home}) {
  return File(path ?? defaultLocalAppBridgeNativeHostStatePath(appId, home: home));
}

Future<void> writeLocalAppBridgeNativeHostState(
  File file,
  LocalAppBridgeNativeHostState state,
) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(state.toJson()));
}

Future<LocalAppBridgeNativeHostState?> readLocalAppBridgeNativeHostState(File file) async {
  if (!file.existsSync()) {
    return null;
  }
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      return null;
    }
    return LocalAppBridgeNativeHostState.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return null;
  }
}
