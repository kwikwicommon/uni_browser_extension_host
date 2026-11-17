import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uni_browser_extension_host/local_app_extension_bridge_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('native host name is derived from the app id', () {
    expect(defaultLocalAppBridgeNativeHostName('transli'), 'com.transli.bridge');
    expect(defaultLocalAppBridgeNativeHostName('VGet Desktop'), 'com.vget.desktop.bridge');
  });

  test('unsandboxed home strips the macOS container prefix', () {
    expect(
      resolveUnsandboxedHome(home: '/Users/chaoren/Library/Containers/net.kwikwi.transli/Data'),
      '/Users/chaoren',
    );
    expect(resolveUnsandboxedHome(home: '/Users/chaoren'), '/Users/chaoren');
  });

  test('codec frames and restores a control-plane message', () {
    const message = <String, Object?>{
      'id': 'req-1',
      'type': kLocalAppBridgeMessageServerInfo,
      'data': <String, Object?>{},
    };
    final framed = LocalAppBridgeNativeMessagingCodec.encode(message);
    expect(framed.length, greaterThan(4));
    final length = ByteData.sublistView(framed, 0, 4).getUint32(0, Endian.little);
    expect(length, framed.length - 4);

    final reader = LocalAppBridgeNativeMessagingReader();
    final decoded = reader.add(framed).toList(growable: false);
    expect(decoded, hasLength(1));
    expect(decoded.single['id'], 'req-1');
    expect(decoded.single['type'], kLocalAppBridgeMessageServerInfo);
  });

  test('codec reader reassembles split frames', () {
    final framed = LocalAppBridgeNativeMessagingCodec.encode(const <String, Object?>{
      'type': kLocalAppBridgeMessagePing,
    });
    final reader = LocalAppBridgeNativeMessagingReader();
    expect(reader.add(framed.sublist(0, 2)).toList(), isEmpty);
    expect(reader.add(framed.sublist(2, 6)).toList(), isEmpty);
    final decoded = reader.add(framed.sublist(6)).toList(growable: false);
    expect(decoded, hasLength(1));
    expect(decoded.single['type'], kLocalAppBridgeMessagePing);
  });

  test('chrome native host manifest uses allowed_origins', () {
    const manifest = LocalAppBridgeNativeHostManifest(
      hostName: 'com.transli.bridge',
      executablePath: '/tmp/native-host',
      allowedChromeExtensionIds: <String>{
        'abcdefghijklmnopabcdefghijklmnop',
        'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
      },
    );
    expect(manifest.toChromeJson(), <String, Object?>{
      'name': 'com.transli.bridge',
      'description': 'Local app extension bridge',
      'path': '/tmp/native-host',
      'type': 'stdio',
      'allowed_origins': <String>[
        'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
        'chrome-extension://abcdefghijklmnopabcdefghijklmnop/',
      ],
    });
  });

  test('firefox native host manifest uses allowed_extensions', () {
    const manifest = LocalAppBridgeNativeHostManifest(
      hostName: 'com.transli.bridge',
      executablePath: '/tmp/native-host',
      allowedFirefoxExtensionIds: <String>{'transli@kwikwi'},
    );
    expect(manifest.toFirefoxJson()['allowed_extensions'], <String>['transli@kwikwi']);
  });

  test('installer writes chrome and firefox manifests under a fake home', () async {
    final root = Directory.systemTemp.createTempSync('bridge-nm-install-');
    addTearDown(() => root.deleteSync(recursive: true));
    final helperDir = Directory('${root.path}/helper');
    final stateFile = File('${root.path}/state.json');
    await stateFile.writeAsString('{"running":false}');

    final installer = LocalAppBridgeNativeHostInstaller(
      homeDirectory: root.path,
      browsers: const <LocalAppBridgeNativeHostBrowser>{
        LocalAppBridgeNativeHostBrowser.chrome,
        LocalAppBridgeNativeHostBrowser.firefox,
      },
      runProcess: (executable, arguments) async {
        expect(<String>['chmod', 'xattr'].contains(executable), isTrue);
        return ProcessResult(0, 0, '', '');
      },
    );
    final result = await installer.install(
      manifest: const LocalAppBridgeNativeHostManifest(
        hostName: 'com.transli.bridge',
        executablePath: '',
        allowedChromeExtensionIds: <String>{'abcdefghijklmnopabcdefghijklmnop'},
        allowedFirefoxExtensionIds: <String>{'transli@kwikwi'},
      ),
      helperDirectory: helperDir,
      stateFile: stateFile,
    );

    expect(result.manifestFiles, hasLength(2));
    final manifests = result.manifestFiles
        .map((file) => jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
        .toList(growable: false);
    final chrome = manifests.firstWhere((item) => item.containsKey('allowed_origins'));
    expect(chrome['path'], result.executablePath);
    expect(chrome['allowed_origins'], <String>[
      'chrome-extension://abcdefghijklmnopabcdefghijklmnop/',
    ]);
    expect(File(result.executablePath).readAsStringSync(), contains(stateFile.absolute.path));
  });

  test('installer preserves registration when the bundled helper is missing', () async {
    final root = Directory.systemTemp.createTempSync('bridge-nm-missing-');
    addTearDown(() => root.deleteSync(recursive: true));
    final manifestFile = LocalAppBridgeNativeHostPaths.manifestFile(
      browser: LocalAppBridgeNativeHostBrowser.chrome,
      hostName: 'com.transli.bridge',
      home: root.path,
    );
    await manifestFile.parent.create(recursive: true);
    const existingRegistration = '{"path":"/existing/native-host"}';
    await manifestFile.writeAsString(existingRegistration);
    final installer = LocalAppBridgeNativeHostInstaller(
      homeDirectory: root.path,
      browsers: const <LocalAppBridgeNativeHostBrowser>{LocalAppBridgeNativeHostBrowser.chrome},
    );
    await expectLater(
      installer.install(
        manifest: LocalAppBridgeNativeHostManifest(
          hostName: 'com.transli.bridge',
          executablePath: '${root.path}/missing-native-host',
        ),
      ),
      throwsStateError,
    );
    expect(await manifestFile.readAsString(), existingRegistration);
  });

  test('stdio host returns live server-info from the running websocket host', () async {
    final root = Directory.systemTemp.createTempSync('bridge-nm-stdio-');
    addTearDown(() => root.deleteSync(recursive: true));
    final stateFile = File('${root.path}/native-host-state.json');
    final storage = MemoryLocalAppBridgeStorage();
    final host = LocalAppBridgeHost(
      config: LocalAppBridgeHostConfig(
        appId: 'transli',
        serverName: 'Transli Desktop',
        portStart: 14755,
        portEnd: 14770,
        nativeMessagingEnabled: true,
        nativeHostStateFile: stateFile.path,
        nativeHostHomeDirectory: root.path,
        supportedFeatures: const <String>[
          kLocalAppBridgeFeaturePing,
          kLocalAppBridgeFeatureStatus,
          kLocalAppBridgeFeatureWebsocket,
          kLocalAppBridgeFeatureControlPlaneV2,
        ],
      ),
      storage: storage,
    );
    addTearDown(() async {
      await host.resetForTesting();
      host.dispose();
    });

    await host.start();
    expect(host.supportedFeatures, contains(kLocalAppBridgeFeatureNativeMessaging));
    final state = await readLocalAppBridgeNativeHostState(stateFile);
    expect(state?.running, isTrue);
    expect(state?.port, host.serverPort);

    final info = await _readServerInfo(host.serverPort!);
    final stdio = LocalAppBridgeNativeMessagingStdioHost(
      stateFile: stateFile,
      fetchServerInfo: (port) async {
        expect(port, host.serverPort);
        return info;
      },
      clock: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
    );
    final reply = await stdio.handle(<String, dynamic>{
      'id': 'nm-1',
      'type': kLocalAppBridgeMessageServerInfo,
      'data': <String, dynamic>{},
    });
    expect(reply['success'], isTrue);
    expect(reply['id'], 'nm-1');
    expect(
      (reply['data'] as Map<String, Object?>)['ws_url'],
      'ws://127.0.0.1:${host.serverPort}/ws',
    );
    expect((reply['data'] as Map<String, Object?>)['native_host_name'], 'com.transli.bridge');
  });

  test('stdio host reports app_not_running when the state file is idle', () async {
    final root = Directory.systemTemp.createTempSync('bridge-nm-idle-');
    addTearDown(() => root.deleteSync(recursive: true));
    final stateFile = File('${root.path}/native-host-state.json');
    await writeLocalAppBridgeNativeHostState(
      stateFile,
      const LocalAppBridgeNativeHostState(
        running: false,
        appId: 'transli',
        serverName: 'Transli Desktop',
        protocolVersion: kLocalAppBridgeProtocolVersion,
      ),
    );
    final stdio = LocalAppBridgeNativeMessagingStdioHost(stateFile: stateFile);
    final reply = await stdio.handle(const <String, dynamic>{
      'id': 'nm-2',
      'type': kLocalAppBridgeMessageServerInfo,
    });
    expect(reply['success'], isFalse);
    expect(reply['error'], 'app_not_running');
  });
}

Future<Map<String, Object?>> _readServerInfo(int port) async {
  final request = await HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/server-info'));
  final response = await request.close();
  return Map<String, Object?>.from(
    jsonDecode(await utf8.decodeStream(response)) as Map<dynamic, dynamic>,
  );
}
