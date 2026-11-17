class LocalAppBridgeHostConfig {
  const LocalAppBridgeHostConfig({
    required this.appId,
    required this.serverName,
    this.protocolVersion = '2.2',
    this.portStart = 13555,
    this.portEnd = 13666,
    this.supportedFeatures = const <String>[
      'ping',
      'status',
      'websocket',
      'control_plane_v2',
    ],
    this.trustedExtensionIds = const <String>{},
    this.defaultExtensionName = 'Extension',
    this.pairingPrefix = 'extension_pairing:v1:',
    this.identityPrefix = 'extension_identity:v1:',
    this.nativeMessagingEnabled = false,
    this.installNativeHost = false,
    this.nativeHostName,
    this.nativeHostStateFile,
    this.nativeHostExecutablePath,
    this.nativeHostHomeDirectory,
    this.allowedChromeExtensionIds = const <String>{},
    this.allowedFirefoxExtensionIds = const <String>{},
  });

  final String appId;
  final String serverName;
  final String protocolVersion;
  final int portStart;
  final int portEnd;
  final List<String> supportedFeatures;
  final Set<String> trustedExtensionIds;
  final String defaultExtensionName;
  final String pairingPrefix;
  final String identityPrefix;
  final bool nativeMessagingEnabled;
  final bool installNativeHost;
  final String? nativeHostName;
  final String? nativeHostStateFile;
  final String? nativeHostExecutablePath;
  final String? nativeHostHomeDirectory;
  final Set<String> allowedChromeExtensionIds;
  final Set<String> allowedFirefoxExtensionIds;
}
