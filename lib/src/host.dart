import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uni_browser_extension_host/src/config.dart';
import 'package:uni_browser_extension_host/src/native_messaging/installer.dart';
import 'package:uni_browser_extension_host/src/native_messaging/manifest.dart';
import 'package:uni_browser_extension_host/src/native_messaging/state.dart';
import 'package:uni_browser_extension_host/src/protocol.dart';
import 'package:uni_browser_extension_host/src/storage.dart';
import 'package:uni_browser_extension_host/src/types.dart';

class _ClientState {
  _ClientState({required this.socket, this.origin});

  final WebSocket socket;
  final String? origin;
  ConnectedExtension? extension;
  bool authenticated = false;
}

class _IssuedChallenge {
  const _IssuedChallenge({required this.issuedAt, required this.identity});

  final DateTime issuedAt;
  final String identity;
}

class _RateWindow {
  _RateWindow(this.windowStart);

  DateTime windowStart;
  int count = 0;
}

class LocalAppBridgeHost extends ChangeNotifier {
  LocalAppBridgeHost({
    required LocalAppBridgeHostConfig config,
    required LocalAppBridgeStorage storage,
    Random? random,
    this.onAuthenticated,
  }) : _config = config,
       _storage = storage,
       _random = random ?? Random.secure();

  static const Duration _challengeTtl = Duration(minutes: 5);
  static const Duration _pairingCodeTtl = Duration(minutes: 10);
  static const int _maxAuthAttemptsPerWindow = 8;
  static const String _serverIdKey = 'server_id';
  static const String _publicKeyFingerprintKey = 'public_key_fingerprint';
  static const String _allowedChromeIdsKey = 'native_host_allowed_chrome_ids';

  final LocalAppBridgeHostConfig _config;
  final LocalAppBridgeStorage _storage;
  final Random _random;
  LocalAppBridgeAuthenticatedCallback? onAuthenticated;
  final Map<String, LocalAppBridgeHandler> _handlers = <String, LocalAppBridgeHandler>{};
  final Map<WebSocket, _ClientState> _clients = <WebSocket, _ClientState>{};
  final Map<String, _IssuedChallenge> _authChallenges = <String, _IssuedChallenge>{};
  final Map<String, _RateWindow> _authRateWindows = <String, _RateWindow>{};

  HttpServer? _server;
  LocalAppBridgeStatus _status = const LocalAppBridgeStatus();
  bool _isInitialized = false;
  bool _isDisposed = false;
  int _clientSerial = 0;
  String? _pairingCode;
  DateTime? _pairingCodeExpiresAt;
  bool _pairingAuthorized = false;
  Future<void> _pairingLock = Future<void>.value();
  String? _serverId;
  String? _publicKeyFingerprint;

  LocalAppBridgeStatus get status => _status;
  bool get isConnected => _status.isConnected;
  bool get isInitialized => _isInitialized;
  bool get isDisposed => _isDisposed;
  int? get serverPort => _status.serverPort;
  String? get pairingCode => _status.pairingCode;
  String get nativeHostName =>
      _config.nativeHostName ?? defaultLocalAppBridgeNativeHostName(_config.appId);

  File get nativeHostStateFile => localAppBridgeNativeHostStateFile(
    _config.appId,
    path: _config.nativeHostStateFile,
    home: _config.nativeHostHomeDirectory,
  );

  List<String> get supportedFeatures {
    final features = <String>[..._config.supportedFeatures];
    if (_config.nativeMessagingEnabled) {
      features.add(kLocalAppBridgeFeatureNativeMessaging);
    }
    return normalizeLocalAppBridgeFeatures(features);
  }

  List<ConnectedExtension> get connectedExtensions => _clients.values
      .map((client) => client.extension)
      .whereType<ConnectedExtension>()
      .toList(growable: false);

  int get authenticatedClientCount => _clients.values
      .where((client) => client.authenticated && client.extension != null)
      .length;

  void registerHandler(String type, LocalAppBridgeHandler handler) {
    _handlers[type] = handler;
  }

  void unregisterHandler(String type) {
    _handlers.remove(type);
  }

  int broadcastToAuthenticatedClients(Map<String, Object?> message) {
    var count = 0;
    for (final client in _clients.values) {
      if (!client.authenticated) {
        continue;
      }
      _send(client.socket, message);
      count++;
    }
    return count;
  }

  Future<void> start() async {
    if (_isInitialized && _server != null) {
      return;
    }
    _isDisposed = false;
    await _ensureIdentity();
    _publish(
      _status.copyWith(
        connectionState: LocalAppBridgeConnectionState.connecting,
        pairingCode: _computeDisplayedPairingCode(),
      ),
    );
    _issueChallenge();
    for (var port = _config.portStart; port <= _config.portEnd; port++) {
      try {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _server = server;
        _isInitialized = true;
        server.listen(_onHttp);
        _publish(
          _status.copyWith(
            connectionState: _clients.isEmpty
                ? LocalAppBridgeConnectionState.disconnected
                : LocalAppBridgeConnectionState.connected,
            serverPort: server.port,
            pairingCode: _computeDisplayedPairingCode(),
            clearError: true,
          ),
        );
        await _syncNativeMessaging(running: true);
        return;
      } catch (_) {
        continue;
      }
    }
    _publish(
      _status.copyWith(
        connectionState: LocalAppBridgeConnectionState.disconnected,
        errorMessage: 'extension_port_unavailable',
        pairingCode: _computeDisplayedPairingCode(),
      ),
    );
  }

  Future<void> stop() async {
    _isDisposed = true;
    _isInitialized = false;
    final server = _server;
    _server = null;
    final sockets = _clients.keys.toList(growable: false);
    _clients.clear();
    for (final socket in sockets) {
      await socket.close();
    }
    await server?.close(force: true);
    await _syncNativeMessaging(running: false);
    _publish(
      _status.copyWith(
        connectionState: LocalAppBridgeConnectionState.disconnected,
        pairingCode: _computeDisplayedPairingCode(),
        clearError: true,
      ),
    );
  }

  String issuePairingCode() {
    final bytes = List<int>.generate(4, (_) => _random.nextInt(256));
    _pairingCode = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _pairingCodeExpiresAt = DateTime.now().toUtc().add(_pairingCodeTtl);
    _pairingAuthorized = true;
    _publish(_status.copyWith(pairingCode: _computeDisplayedPairingCode()));
    return _pairingCode!;
  }

  void authorizeNextPairing() {
    _pairingAuthorized = true;
  }

  Future<void> resetForTesting() async {
    await stop();
    _authChallenges.clear();
    _authRateWindows.clear();
    _pairingCode = null;
    _pairingCodeExpiresAt = null;
    _pairingAuthorized = false;
    _clientSerial = 0;
    _isDisposed = false;
  }

  Future<void> _ensureIdentity() async {
    _serverId = await _readOrCreateIdentity(_config.identityPrefix + _serverIdKey);
    _publicKeyFingerprint = await _readOrCreateIdentity(
      _config.identityPrefix + _publicKeyFingerprintKey,
    );
  }

  Future<String> _readOrCreateIdentity(String key) async {
    final stored = await _storage.read(key);
    if (stored != null && stored.trim().isNotEmpty) {
      return stored.trim();
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final value = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key, value);
    return value;
  }

  Future<void> _onHttp(HttpRequest request) async {
    _applyCors(request);
    final path = request.uri.path;
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (WebSocketTransformer.isUpgradeRequest(request) && path == '/ws') {
      final origin = request.headers.value('origin');
      if (!_originAllowed(origin)) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.headers.contentType = ContentType.json;
        final bytes = utf8.encode(
          jsonEncode(<String, Object?>{'success': false, 'error': 'origin_rejected'}),
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _clients[socket] = _ClientState(socket: socket, origin: origin);
      socket.listen(
        (dynamic raw) => unawaited(_onSocketMessage(socket, raw)),
        onDone: () => _forget(socket),
        onError: (_) => _forget(socket),
      );
      return;
    }
    request.response.headers.contentType = ContentType.json;
    final Object payload;
    if (request.method == 'GET' && path == '/server-info') {
      // Discovery challenges must stay unbound. Chrome sends Origin on fetch,
      // but auth matches `$extensionUuid:$extensionId`, not the HTTP origin.
      payload = _serverInfo(_issueChallenge());
    } else {
      request.response.statusCode = HttpStatus.notFound;
      payload = <String, Object?>{'success': false, 'error': 'not_found'};
    }
    final bytes = utf8.encode(jsonEncode(payload));
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  int? get _listeningPort {
    final server = _server;
    if (server == null) {
      return null;
    }
    try {
      return server.port;
    } on HttpException {
      return null;
    }
  }

  Map<String, Object?> _serverInfo(String challenge) {
    final port = _listeningPort;
    final features = supportedFeatures;
    return <String, Object?>{
      'status': 'ok',
      'port': port,
      'app_id': _config.appId,
      'appId': _config.appId,
      'features': features,
      'supported_features': features,
      'supportedFeatures': features,
      'server_name': _config.serverName,
      'serverName': _config.serverName,
      'server_id': _serverId,
      'serverId': _serverId,
      'protocol_version': _config.protocolVersion,
      'protocolVersion': _config.protocolVersion,
      'public_key_fingerprint': _publicKeyFingerprint,
      'publicKeyFingerprint': _publicKeyFingerprint,
      'ws_url': port == null ? null : 'ws://127.0.0.1:$port/ws',
      'wsUrl': port == null ? null : 'ws://127.0.0.1:$port/ws',
      'auth_challenge': challenge,
      'authChallenge': challenge,
      'pairing_code': _computeDisplayedPairingCode(),
      'pairingCode': _computeDisplayedPairingCode(),
      if (_config.nativeMessagingEnabled) ...<String, Object?>{
        'native_host_name': nativeHostName,
        'nativeHostName': nativeHostName,
      },
    };
  }

  String _computeDisplayedPairingCode() {
    final identity = jsonEncode(<String, Object?>{
      'version': 1,
      'appId': _config.appId,
      'serverName': _config.serverName,
      'serverId': _serverId ?? '',
      'protocolVersion': _config.protocolVersion,
      'endpoint': _listeningPort == null
          ? 'ws://localhost:${_config.portStart}/ws'
          : 'ws://127.0.0.1:${_listeningPort}/ws',
      'port': _listeningPort ?? _config.portStart,
      'publicKeyFingerprint': _publicKeyFingerprint ?? '',
    });
    final fingerprint = sha256.convert(utf8.encode(identity)).toString();
    return formatLocalAppBridgePairingCode(fingerprint);
  }

  Future<void> _onSocketMessage(WebSocket socket, dynamic raw) async {
    final text = raw is String ? raw : utf8.decode(raw as List<int>);
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      return;
    }
    final message = Map<String, dynamic>.from(decoded);
    final type = message['type']?.toString() ?? '';
    final id = message['id']?.toString() ?? '';
    final data = message['data'];
    final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final client = _clients[socket];
    if (client == null) {
      return;
    }
    switch (type) {
      case kLocalAppBridgeMessageAuth:
        await _handleAuth(client, id, payload);
      case kLocalAppBridgeMessagePing:
        _reply(socket, id, const LocalAppBridgeReply(success: true, data: <String, Object?>{
          'status': 'ok',
        }));
      case kLocalAppBridgeMessageStatus:
        if (!_requireAuth(client, socket, id)) {
          return;
        }
        _reply(socket, id, LocalAppBridgeReply.ok(_statusPayload()));
      case kLocalAppBridgeMessageExtensionStatus:
        if (!_requireAuth(client, socket, id)) {
          return;
        }
        _handleExtensionStatus(client, id, payload);
      default:
        if (!_requireAuth(client, socket, id)) {
          return;
        }
        final handler = _handlers[type];
        if (handler == null) {
          _reply(socket, id, LocalAppBridgeReply.fail('unsupported_message'));
          return;
        }
        try {
          final reply = await handler(
            LocalAppBridgeRequest(
              id: id,
              type: type,
              data: payload,
              extension: client.extension,
            ),
          );
          _reply(socket, id, reply);
        } catch (error) {
          _reply(socket, id, LocalAppBridgeReply.fail(error.toString()));
        }
    }
  }

  Map<String, Object?> _statusPayload() {
    return <String, Object?>{
      'connected': true,
      'port': _listeningPort,
      'features': supportedFeatures,
      'supported_features': supportedFeatures,
      'supportedFeatures': supportedFeatures,
    };
  }

  bool _requireAuth(_ClientState client, WebSocket socket, String id) {
    if (client.authenticated) {
      return true;
    }
    _reply(socket, id, LocalAppBridgeReply.fail('unauthenticated'));
    return false;
  }

  Future<void> _handleAuth(
    _ClientState client,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final extensionId = payload['extension_id']?.toString().trim() ?? '';
    final extensionUuid = payload['extension_uuid']?.toString().trim() ?? '';
    final response = payload['response']?.toString().trim() ?? '';
    final authMode = payload['auth_mode']?.toString().trim() ?? '';
    if (extensionId.isEmpty || extensionUuid.isEmpty || response.isEmpty) {
      _replyAuth(client.socket, id, authenticated: false, error: 'invalid_auth');
      return;
    }
    if (!_allowAuthAttempt('$extensionId:$extensionUuid')) {
      _replyAuth(client.socket, id, authenticated: false, error: 'rate_limited');
      return;
    }
    if (!_identityMatchesOrigin(client.origin, extensionId)) {
      _replyAuth(client.socket, id, authenticated: false, error: 'origin_rejected');
      return;
    }
    await _runSerializedPairing(() async {
      final stored = await _readPairingRecord(extensionUuid);
      final token = authMode == 'register'
          ? payload['token']?.toString() ?? ''
          : stored?['token'] ?? '';
      if (token.isEmpty) {
        _replyAuth(
          client.socket,
          id,
          authenticated: false,
          error: authMode == 'reconnect' ? 'pairing_not_found' : 'invalid_auth',
        );
        return;
      }
      final identity = '$extensionUuid:$extensionId';
      final matchedChallenge = _matchChallenge(
        token: token,
        response: response,
        extensionUuid: extensionUuid,
        extensionId: extensionId,
        identity: identity,
      );
      if (matchedChallenge == null) {
        _replyAuth(client.socket, id, authenticated: false, error: 'auth_rejected');
        return;
      }
      if (authMode == 'register') {
        final allowed = _consumePairingAuthorization(
          payload['pairing_code']?.toString().trim() ?? '',
        );
        if (stored != null && stored['token'] != token) {
          final previousToken = payload['previous_token']?.toString() ?? '';
          if (previousToken != stored['token'] && !allowed) {
            _replyAuth(client.socket, id, authenticated: false, error: 'reauth_required');
            return;
          }
        } else if (stored == null && !allowed) {
          _replyAuth(
            client.socket,
            id,
            authenticated: false,
            error: 'pairing_authorization_required',
          );
          return;
        }
        await _writePairingToken(extensionUuid, token, extensionId);
      }
      client.authenticated = true;
      client.extension = ConnectedExtension(
        clientId: 'client-${++_clientSerial}',
        extensionUuid: extensionUuid,
        extensionId: extensionId,
        version: payload['version']?.toString() ?? '',
        name: payload['name']?.toString() ?? _config.defaultExtensionName,
        browserName:
            payload['browser_name']?.toString() ?? payload['browserName']?.toString() ?? 'browser',
        contentFingerprint: payload['content_fingerprint']?.toString() ?? '',
      );
      _publishTrustedStatus();
      _replyAuth(client.socket, id, authenticated: true);
      final extension = client.extension;
      if (extension != null) {
        onAuthenticated?.call(extension);
      }
      await _rememberNativeMessagingOrigin(client.origin ?? extensionId);
    });
  }

  void _handleExtensionStatus(
    _ClientState client,
    String id,
    Map<String, dynamic> payload,
  ) {
    final existing = client.extension;
    if (existing != null) {
      client.extension = ConnectedExtension(
        clientId: existing.clientId,
        extensionUuid: payload['extension_uuid']?.toString() ?? existing.extensionUuid,
        extensionId: payload['extension_id']?.toString() ?? existing.extensionId,
        version: payload['version']?.toString() ?? existing.version,
        name: payload['name']?.toString() ?? existing.name,
        browserName:
            payload['browser_name']?.toString() ??
            payload['browserName']?.toString() ??
            existing.browserName,
        contentFingerprint:
            payload['content_fingerprint']?.toString() ?? existing.contentFingerprint,
      );
    }
    _publishTrustedStatus();
    _reply(
      client.socket,
      id,
      LocalAppBridgeReply.ok(<String, Object?>{
        'supported_features': supportedFeatures,
        'supportedFeatures': supportedFeatures,
        'needsUpdate': false,
      }),
    );
  }

  void _replyAuth(
    WebSocket socket,
    String id, {
    required bool authenticated,
    String? error,
  }) {
    _reply(
      socket,
      id,
      LocalAppBridgeReply(
        success: authenticated,
        data: <String, Object?>{
          'authenticated': authenticated,
          if (error != null) 'reason': error,
        },
        error: error,
      ),
    );
  }

  void _reply(WebSocket socket, String id, LocalAppBridgeReply reply) {
    _send(socket, <String, Object?>{
      'id': id,
      'success': reply.success,
      'data': reply.data,
      if (reply.error != null) 'error': reply.error,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _forget(WebSocket socket) {
    _clients.remove(socket);
    if (authenticatedClientCount == 0) {
      _pairingAuthorized = true;
    }
    _publishTrustedStatus();
  }

  void _publishTrustedStatus() {
    final trusted = connectedExtensions;
    if (trusted.isEmpty) {
      _publish(
        _status.copyWith(
          connectionState: LocalAppBridgeConnectionState.disconnected,
          serverPort: _listeningPort,
          pairingCode: _computeDisplayedPairingCode(),
        ),
      );
      return;
    }
    _publish(
      _status.copyWith(
        connectionState: LocalAppBridgeConnectionState.connected,
        serverPort: _listeningPort,
        pairingCode: _computeDisplayedPairingCode(),
        clearError: true,
      ),
    );
  }

  void _publish(LocalAppBridgeStatus status) {
    _status = status;
    notifyListeners();
  }

  void _send(WebSocket socket, Map<String, Object?> message) {
    socket.add(jsonEncode(message));
  }

  String _issueChallenge({String identity = ''}) {
    _pruneChallenges();
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final challenge = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _authChallenges[challenge] = _IssuedChallenge(
      issuedAt: DateTime.now().toUtc(),
      identity: identity,
    );
    return challenge;
  }

  void _pruneChallenges() {
    final cutoff = DateTime.now().toUtc().subtract(_challengeTtl);
    _authChallenges.removeWhere((_, issued) => issued.issuedAt.isBefore(cutoff));
  }

  String? _matchChallenge({
    required String token,
    required String response,
    required String extensionUuid,
    required String extensionId,
    required String identity,
  }) {
    _pruneChallenges();
    final expectedResponse = response.toLowerCase();
    for (final challenge in _authChallenges.keys.toList(growable: false)) {
      final issued = _authChallenges[challenge];
      if (issued != null && issued.identity.isNotEmpty && issued.identity != identity) {
        continue;
      }
      final expected = _hmacHex(
        token: token,
        challenge: challenge,
        extensionUuid: extensionUuid,
        extensionId: extensionId,
      );
      if (expected == expectedResponse) {
        _authChallenges.remove(challenge);
        return challenge;
      }
    }
    return null;
  }

  String _hmacHex({
    required String token,
    required String challenge,
    required String extensionUuid,
    required String extensionId,
  }) {
    final hmac = Hmac(sha256, utf8.encode(token));
    return hmac.convert(utf8.encode('$challenge:$extensionUuid:$extensionId')).toString();
  }

  Future<Map<String, String>?> _readPairingRecord(String extensionUuid) async {
    final raw = await _storage.read('${_config.pairingPrefix}$extensionUuid');
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final token = decoded['token']?.toString() ?? '';
        if (token.isEmpty) {
          return null;
        }
        return <String, String>{
          'token': token,
          'extensionId': decoded['extensionId']?.toString() ?? '',
        };
      }
    } catch (_) {}
    return null;
  }

  bool _isExtensionOrigin(String origin) {
    final normalized = origin.trim().toLowerCase();
    return normalized.startsWith('chrome-extension://') ||
        normalized.startsWith('moz-extension://') ||
        normalized.startsWith('safari-web-extension://');
  }

  bool _originAllowed(String? origin) {
    if (origin == null || origin.trim().isEmpty) {
      return true;
    }
    // Unpacked Chrome IDs change every load. Pairing + HMAC is the real gate.
    return _isExtensionOrigin(origin);
  }

  bool _identityMatchesOrigin(String? origin, String extensionId) {
    if (origin == null || origin.trim().isEmpty) {
      return true;
    }
    if (!_originAllowed(origin)) {
      return false;
    }
    final host = Uri.tryParse(origin)?.host ?? '';
    if (host.isEmpty) {
      return true;
    }
    return host == extensionId;
  }

  bool _allowAuthAttempt(String key) {
    final now = DateTime.now().toUtc();
    final window = _authRateWindows.putIfAbsent(key, () => _RateWindow(now));
    if (now.difference(window.windowStart) > const Duration(minutes: 1)) {
      window.windowStart = now;
      window.count = 0;
    }
    window.count++;
    return window.count <= _maxAuthAttemptsPerWindow;
  }

  bool _consumePairingAuthorization(String pairingCode) {
    final expected = _pairingCode;
    final expires = _pairingCodeExpiresAt;
    final codeValid =
        expected != null &&
        expires != null &&
        DateTime.now().toUtc().isBefore(expires) &&
        pairingCode.isNotEmpty &&
        pairingCode == expected;
    if (codeValid) {
      _pairingCode = null;
      _pairingAuthorized = false;
      return true;
    }
    if (_pairingAuthorized) {
      _pairingAuthorized = false;
      return true;
    }
    return false;
  }

  void _applyCors(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null || !_originAllowed(origin)) {
      return;
    }
    request.response.headers.set('Access-Control-Allow-Origin', origin);
    request.response.headers.set('Access-Control-Allow-Headers', 'content-type, accept');
    request.response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    request.response.headers.set('Vary', 'Origin');
  }

  Future<void> _runSerializedPairing(Future<void> Function() action) {
    final next = _pairingLock.catchError((_) {}).then((_) => action());
    _pairingLock = next.catchError((_) {});
    return next;
  }

  Future<void> _writePairingToken(
    String extensionUuid,
    String token,
    String extensionId,
  ) async {
    await _storage.write(
      '${_config.pairingPrefix}$extensionUuid',
      jsonEncode(<String, String>{
        'token': token,
        'extensionId': extensionId,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  Future<void> _syncNativeMessaging({required bool running}) async {
    if (!_config.nativeMessagingEnabled) {
      return;
    }
    try {
      await writeLocalAppBridgeNativeHostState(
        nativeHostStateFile,
        LocalAppBridgeNativeHostState(
          running: running && _listeningPort != null,
          appId: _config.appId,
          serverName: _config.serverName,
          protocolVersion: _config.protocolVersion,
          port: running ? _listeningPort : null,
          wsUrl: running && _listeningPort != null
              ? 'ws://127.0.0.1:$_listeningPort/ws'
              : null,
          nativeHostName: nativeHostName,
          supportedFeatures: supportedFeatures,
        ),
      );
      if (running && _config.installNativeHost) {
        await installNativeMessagingHost();
      }
    } catch (error) {
      debugPrint('Native messaging host sync failed: $error');
    }
  }

  Future<void> installNativeMessagingHost() async {
    if (!_config.nativeMessagingEnabled) {
      return;
    }
    final allowedChromeIds = <String>{
      ..._config.allowedChromeExtensionIds,
      ...await _readAllowedChromeIds(),
    };
    final helperDirectory = nativeHostStateFile.parent;
    await LocalAppBridgeNativeHostInstaller(
      homeDirectory: _config.nativeHostHomeDirectory,
    ).install(
      manifest: LocalAppBridgeNativeHostManifest(
        hostName: nativeHostName,
        executablePath: _config.nativeHostExecutablePath ?? '',
        description: '${_config.serverName} native messaging host',
        allowedChromeExtensionIds: allowedChromeIds,
        allowedFirefoxExtensionIds: _config.allowedFirefoxExtensionIds,
      ),
      helperDirectory: helperDirectory,
      stateFile: nativeHostStateFile,
    );
  }

  Future<void> _rememberNativeMessagingOrigin(String? origin) async {
    if (!_config.nativeMessagingEnabled) {
      return;
    }
    final chromeId =
        chromeExtensionIdFromOrigin(origin) ??
        chromeExtensionIdFromOrigin(normalizeChromeExtensionOrigin(origin ?? ''));
    if (chromeId == null) {
      return;
    }
    final stored = await _readAllowedChromeIds();
    if (!stored.add(chromeId)) {
      return;
    }
    await _storage.write(_allowedChromeIdsKey, jsonEncode(stored.toList(growable: false)));
    if (_config.installNativeHost) {
      try {
        await installNativeMessagingHost();
      } catch (error) {
        debugPrint('Native messaging host update failed: $error');
      }
    }
  }

  Future<Set<String>> _readAllowedChromeIds() async {
    final raw = await _storage.read(_allowedChromeIdsKey);
    if (raw == null || raw.isEmpty) {
      return <String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <String>{};
      }
      return decoded
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }
}
