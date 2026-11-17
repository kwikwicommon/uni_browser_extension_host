import 'dart:convert';
import 'dart:io';

import 'package:uni_browser_extension_host/src/native_messaging/state.dart';

enum LocalAppBridgeNativeHostBrowser { chrome, chromeCanary, chromium, edge, brave, firefox }

class LocalAppBridgeNativeHostManifest {
  const LocalAppBridgeNativeHostManifest({
    required this.hostName,
    required this.executablePath,
    this.description = 'Local app extension bridge',
    this.allowedChromeExtensionIds = const <String>{},
    this.allowedFirefoxExtensionIds = const <String>{},
  });

  final String hostName;
  final String executablePath;
  final String description;
  final Set<String> allowedChromeExtensionIds;
  final Set<String> allowedFirefoxExtensionIds;

  Map<String, Object?> toChromeJson() {
    return <String, Object?>{
      'name': hostName,
      'description': description,
      'path': executablePath,
      'type': 'stdio',
      'allowed_origins': (allowedChromeExtensionIds
              .map(normalizeChromeExtensionOrigin)
              .whereType<String>()
              .toList()
            ..sort()),
    };
  }

  Map<String, Object?> toFirefoxJson() {
    return <String, Object?>{
      'name': hostName,
      'description': description,
      'path': executablePath,
      'type': 'stdio',
      'allowed_extensions': (allowedFirefoxExtensionIds
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toList()
            ..sort()),
    };
  }
}

String? normalizeChromeExtensionOrigin(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  if (trimmed.startsWith('chrome-extension://')) {
    final uri = Uri.tryParse(trimmed.endsWith('/') ? trimmed : '$trimmed/');
    final host = uri?.host ?? '';
    if (host.isEmpty) {
      return null;
    }
    return 'chrome-extension://$host/';
  }
  if (RegExp(r'^[a-p]{32}$').hasMatch(trimmed)) {
    return 'chrome-extension://$trimmed/';
  }
  return null;
}

String? chromeExtensionIdFromOrigin(String? origin) {
  if (origin == null || origin.trim().isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.scheme != 'chrome-extension') {
    return null;
  }
  final host = uri.host.trim();
  return host.isEmpty ? null : host;
}

class LocalAppBridgeNativeHostPaths {
  static File manifestFile({
    required LocalAppBridgeNativeHostBrowser browser,
    required String hostName,
    String? home,
  }) {
    final resolvedHome = resolveUnsandboxedHome(home: home);
    final fileName = '$hostName.json';
    if (Platform.isWindows) {
      return File('${_windowsManifestDirectory(browser, resolvedHome)}$fileName');
    }
    return File('${_unixManifestDirectory(browser, resolvedHome)}/$fileName');
  }

  static String _unixManifestDirectory(
    LocalAppBridgeNativeHostBrowser browser,
    String home,
  ) {
    if (Platform.isMacOS) {
      switch (browser) {
        case LocalAppBridgeNativeHostBrowser.chrome:
          return '$home/Library/Application Support/Google/Chrome/NativeMessagingHosts';
        case LocalAppBridgeNativeHostBrowser.chromeCanary:
          return '$home/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts';
        case LocalAppBridgeNativeHostBrowser.chromium:
          return '$home/Library/Application Support/Chromium/NativeMessagingHosts';
        case LocalAppBridgeNativeHostBrowser.edge:
          return '$home/Library/Application Support/Microsoft Edge/NativeMessagingHosts';
        case LocalAppBridgeNativeHostBrowser.brave:
          return '$home/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts';
        case LocalAppBridgeNativeHostBrowser.firefox:
          return '$home/Library/Application Support/Mozilla/NativeMessagingHosts';
      }
    }
    switch (browser) {
      case LocalAppBridgeNativeHostBrowser.chrome:
        return '$home/.config/google-chrome/NativeMessagingHosts';
      case LocalAppBridgeNativeHostBrowser.chromeCanary:
        return '$home/.config/google-chrome-unstable/NativeMessagingHosts';
      case LocalAppBridgeNativeHostBrowser.chromium:
        return '$home/.config/chromium/NativeMessagingHosts';
      case LocalAppBridgeNativeHostBrowser.edge:
        return '$home/.config/microsoft-edge/NativeMessagingHosts';
      case LocalAppBridgeNativeHostBrowser.brave:
        return '$home/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts';
      case LocalAppBridgeNativeHostBrowser.firefox:
        return '$home/.mozilla/native-messaging-hosts';
    }
  }

  static String _windowsManifestDirectory(
    LocalAppBridgeNativeHostBrowser browser,
    String home,
  ) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    switch (browser) {
      case LocalAppBridgeNativeHostBrowser.firefox:
        return '$localAppData\\local-app-extension-bridge\\Mozilla\\NativeMessagingHosts\\';
      case LocalAppBridgeNativeHostBrowser.edge:
        return '$localAppData\\local-app-extension-bridge\\Edge\\NativeMessagingHosts\\';
      case LocalAppBridgeNativeHostBrowser.brave:
        return '$localAppData\\local-app-extension-bridge\\Brave\\NativeMessagingHosts\\';
      case LocalAppBridgeNativeHostBrowser.chrome:
      case LocalAppBridgeNativeHostBrowser.chromeCanary:
      case LocalAppBridgeNativeHostBrowser.chromium:
        return '$localAppData\\local-app-extension-bridge\\Chrome\\NativeMessagingHosts\\';
    }
  }

  static String windowsRegistryKey(LocalAppBridgeNativeHostBrowser browser, String hostName) {
    switch (browser) {
      case LocalAppBridgeNativeHostBrowser.firefox:
        return 'HKCU\\Software\\Mozilla\\NativeMessagingHosts\\$hostName';
      case LocalAppBridgeNativeHostBrowser.edge:
        return 'HKCU\\Software\\Microsoft\\Edge\\NativeMessagingHosts\\$hostName';
      case LocalAppBridgeNativeHostBrowser.brave:
        return 'HKCU\\Software\\BraveSoftware\\Brave\\NativeMessagingHosts\\$hostName';
      case LocalAppBridgeNativeHostBrowser.chromeCanary:
        return 'HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\$hostName';
      case LocalAppBridgeNativeHostBrowser.chromium:
        return 'HKCU\\Software\\Chromium\\NativeMessagingHosts\\$hostName';
      case LocalAppBridgeNativeHostBrowser.chrome:
        return 'HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\$hostName';
    }
  }
}

String encodeLocalAppBridgeNativeHostManifest(Map<String, Object?> manifest) {
  return const JsonEncoder.withIndent('  ').convert(manifest);
}
