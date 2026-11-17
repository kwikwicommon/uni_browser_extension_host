import 'dart:io';

import 'package:uni_browser_extension_host/local_app_extension_bridge_host.dart';

Future<void> main(List<String> args) async {
  final statePath =
      Platform.environment['LOCAL_APP_BRIDGE_STATE'] ??
      (args.isNotEmpty ? args.first : null) ??
      defaultLocalAppBridgeNativeHostStatePath(
        Platform.environment['LOCAL_APP_BRIDGE_APP_ID'] ?? 'localapp',
      );
  await LocalAppBridgeNativeMessagingStdioHost(stateFile: File(statePath)).run();
}
