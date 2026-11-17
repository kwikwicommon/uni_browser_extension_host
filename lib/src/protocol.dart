const String kLocalAppBridgeProtocolVersion = '2.2';

const String kLocalAppBridgeMessageAuth = 'auth';
const String kLocalAppBridgeMessagePing = 'ping';
const String kLocalAppBridgeMessageStatus = 'status';
const String kLocalAppBridgeMessageExtensionStatus = 'extension_status';
const String kLocalAppBridgeMessageServerInfo = 'server_info';
const String kLocalAppBridgeMessageImageOcr = 'image_ocr';

const String kLocalAppBridgeFeaturePing = 'ping';
const String kLocalAppBridgeFeatureStatus = 'status';
const String kLocalAppBridgeFeatureWebsocket = 'websocket';
const String kLocalAppBridgeFeatureNativeMessaging = 'native_messaging';
const String kLocalAppBridgeFeatureControlPlaneV2 = 'control_plane_v2';
const String kLocalAppBridgeFeatureAppleOcr = 'apple_ocr';
const String kLocalAppBridgeFeatureImageOcr = 'image_ocr';

String defaultLocalAppBridgeNativeHostName(String appId) {
  final slug = appId.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '.');
  final compact = slug.replaceAll(RegExp(r'^\.+|\.+$'), '');
  return 'com.${compact.isEmpty ? 'localapp' : compact}.bridge';
}

String formatLocalAppBridgePairingCode(String fingerprint) {
  final normalized = fingerprint.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final clipped = normalized.padRight(12, '0').substring(0, 12);
  return '${clipped.substring(0, 4)}-${clipped.substring(4, 8)}-${clipped.substring(8, 12)}';
}

List<String> normalizeLocalAppBridgeFeatures(Iterable<String> features) {
  return features
      .map((feature) => feature.trim())
      .where((feature) => feature.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
