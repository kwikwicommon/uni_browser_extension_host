enum LocalAppBridgeConnectionState { idle, connecting, connected, disconnected }

enum LocalAppBridgeTransport { websocket, nativeMessaging }

extension LocalAppBridgeTransportId on LocalAppBridgeTransport {
  String get id {
    switch (this) {
      case LocalAppBridgeTransport.websocket:
        return 'websocket';
      case LocalAppBridgeTransport.nativeMessaging:
        return 'native_messaging';
    }
  }
}

class ConnectedExtension {
  const ConnectedExtension({
    required this.clientId,
    required this.extensionUuid,
    required this.extensionId,
    required this.version,
    required this.name,
    required this.browserName,
    this.contentFingerprint = '',
    this.transport = LocalAppBridgeTransport.websocket,
  });

  final String clientId;
  final String extensionUuid;
  final String extensionId;
  final String version;
  final String name;
  final String browserName;
  final String contentFingerprint;
  final LocalAppBridgeTransport transport;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'clientId': clientId,
      'extensionUuid': extensionUuid,
      'extensionId': extensionId,
      'version': version,
      'name': name,
      'browserName': browserName,
      'contentFingerprint': contentFingerprint,
      'transport': transport.id,
    };
  }
}

class LocalAppBridgeRequest {
  const LocalAppBridgeRequest({
    required this.id,
    required this.type,
    required this.data,
    this.extension,
  });

  final String id;
  final String type;
  final Map<String, dynamic> data;
  final ConnectedExtension? extension;
}

class LocalAppBridgeReply {
  const LocalAppBridgeReply({
    required this.success,
    this.data = const <String, Object?>{},
    this.error,
  });

  final bool success;
  final Map<String, Object?> data;
  final String? error;

  factory LocalAppBridgeReply.ok([Map<String, Object?> data = const <String, Object?>{}]) {
    return LocalAppBridgeReply(success: true, data: data);
  }

  factory LocalAppBridgeReply.fail(
    String error, {
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    return LocalAppBridgeReply(success: false, error: error, data: data);
  }
}

class LocalAppBridgeStatus {
  const LocalAppBridgeStatus({
    this.connectionState = LocalAppBridgeConnectionState.idle,
    this.serverPort,
    this.errorMessage,
    this.pairingCode,
  });

  final LocalAppBridgeConnectionState connectionState;
  final int? serverPort;
  final String? errorMessage;
  final String? pairingCode;

  bool get isConnected => connectionState == LocalAppBridgeConnectionState.connected;

  LocalAppBridgeStatus copyWith({
    LocalAppBridgeConnectionState? connectionState,
    int? serverPort,
    String? errorMessage,
    String? pairingCode,
    bool clearError = false,
  }) {
    return LocalAppBridgeStatus(
      connectionState: connectionState ?? this.connectionState,
      serverPort: serverPort ?? this.serverPort,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      pairingCode: pairingCode ?? this.pairingCode,
    );
  }
}

typedef LocalAppBridgeHandler =
    Future<LocalAppBridgeReply> Function(LocalAppBridgeRequest request);

typedef LocalAppBridgeAuthenticatedCallback = void Function(ConnectedExtension extension);
