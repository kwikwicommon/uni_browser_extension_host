import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:uni_browser_extension_host/src/native_messaging/manifest.dart';

typedef LocalAppBridgeProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class LocalAppBridgeNativeHostInstallResult {
  const LocalAppBridgeNativeHostInstallResult({
    required this.executablePath,
    required this.manifestFiles,
  });

  final String executablePath;
  final List<File> manifestFiles;
}

class LocalAppBridgeNativeHostInstaller {
  LocalAppBridgeNativeHostInstaller({
    this.homeDirectory,
    this.browsers = const <LocalAppBridgeNativeHostBrowser>{
      LocalAppBridgeNativeHostBrowser.chrome,
      LocalAppBridgeNativeHostBrowser.edge,
      LocalAppBridgeNativeHostBrowser.chromium,
      LocalAppBridgeNativeHostBrowser.brave,
      LocalAppBridgeNativeHostBrowser.firefox,
    },
    LocalAppBridgeProcessRunner? runProcess,
  }) : _runProcess = runProcess ?? Process.run;

  final String? homeDirectory;
  final Set<LocalAppBridgeNativeHostBrowser> browsers;
  final LocalAppBridgeProcessRunner _runProcess;

  Future<LocalAppBridgeNativeHostInstallResult> install({
    required LocalAppBridgeNativeHostManifest manifest,
    Directory? helperDirectory,
    File? stateFile,
  }) async {
    final executablePath = await _resolveExecutable(
      manifest: manifest,
      helperDirectory: helperDirectory,
      stateFile: stateFile,
    );
    final resolved = LocalAppBridgeNativeHostManifest(
      hostName: manifest.hostName,
      executablePath: executablePath,
      description: manifest.description,
      allowedChromeExtensionIds: manifest.allowedChromeExtensionIds,
      allowedFirefoxExtensionIds: manifest.allowedFirefoxExtensionIds,
    );
    final files = <File>[];
    for (final browser in browsers) {
      try {
        final file = LocalAppBridgeNativeHostPaths.manifestFile(
          browser: browser,
          hostName: resolved.hostName,
          home: homeDirectory,
        );
        await file.parent.create(recursive: true);
        final payload = browser == LocalAppBridgeNativeHostBrowser.firefox
            ? resolved.toFirefoxJson()
            : resolved.toChromeJson();
        await file.writeAsString(encodeLocalAppBridgeNativeHostManifest(payload));
        files.add(file);
        if (Platform.isWindows) {
          await _registerWindowsHost(browser, resolved.hostName, file);
        }
      } catch (_) {
        // One browser profile must not block Chrome or the helper.
      }
    }
    return LocalAppBridgeNativeHostInstallResult(
      executablePath: executablePath,
      manifestFiles: files,
    );
  }

  Future<void> uninstall({required String hostName}) async {
    for (final browser in browsers) {
      final file = LocalAppBridgeNativeHostPaths.manifestFile(
        browser: browser,
        hostName: hostName,
        home: homeDirectory,
      );
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  Future<File> materializeUnixHelper({
    required Directory directory,
    required File stateFile,
  }) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/native-host');
    await file.writeAsString(buildUnixNativeHostHelperSource(stateFile.absolute.path));
    if (!Platform.isWindows) {
      await _runProcess('chmod', <String>['755', file.path]);
      clearMacQuarantineAttribute(file.path);
    }
    return file;
  }

  Future<String> _resolveExecutable({
    required LocalAppBridgeNativeHostManifest manifest,
    Directory? helperDirectory,
    File? stateFile,
  }) async {
    if (manifest.executablePath.trim().isNotEmpty) {
      final executable = File(manifest.executablePath).absolute;
      if (!await executable.exists()) {
        throw StateError('Native messaging executable is missing: ${executable.path}');
      }
      return executable.path;
    }
    if (Platform.isWindows) {
      throw StateError('A compiled native messaging executable is required on Windows.');
    }
    if (helperDirectory == null || stateFile == null) {
      throw StateError('Native messaging helper directory and state file are required.');
    }
    final helper = await materializeUnixHelper(directory: helperDirectory, stateFile: stateFile);
    return helper.absolute.path;
  }

  Future<void> _registerWindowsHost(
    LocalAppBridgeNativeHostBrowser browser,
    String hostName,
    File manifestFile,
  ) async {
    try {
      await _runProcess('reg', <String>[
        'add',
        LocalAppBridgeNativeHostPaths.windowsRegistryKey(browser, hostName),
        '/ve',
        '/t',
        'REG_SZ',
        '/d',
        manifestFile.absolute.path,
        '/f',
      ]);
    } catch (_) {
      // Registry registration is best-effort; the JSON manifest is still written.
    }
  }
}

String buildUnixNativeHostHelperSource(String stateFilePath) {
  final escaped = stateFilePath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  return '''
#!/usr/bin/env ruby
# Generated by local_app_extension_bridge_host. Do not edit.
require "json"
require "net/http"
require "uri"

STATE_FILE = '$escaped'

def read_message
  header = STDIN.read(4)
  return nil if header.nil? || header.bytesize < 4
  length = header.unpack1("L<")
  return nil if length.nil? || length <= 0 || length > 1024 * 1024
  body = STDIN.read(length)
  return nil if body.nil?
  JSON.parse(body)
end

def write_message(payload)
  json = JSON.generate(payload)
  STDOUT.write([json.bytesize].pack("L<"))
  STDOUT.write(json)
  STDOUT.flush
end

def server_info
  unless File.exist?(STATE_FILE)
    return { "success" => false, "error" => "app_not_running", "data" => {} }
  end
  state = JSON.parse(File.read(STATE_FILE))
  port = state["port"]
  unless state["running"] && port
    return { "success" => false, "error" => "app_not_running", "data" => {} }
  end
  uri = URI("http://127.0.0.1:#{port}/server-info")
  response = Net::HTTP.get_response(uri)
  data = JSON.parse(response.body)
  { "success" => true, "data" => data }
rescue
  { "success" => false, "error" => "server_info_unavailable", "data" => {} }
end

loop do
  message = read_message
  break if message.nil?
  type = message["type"].to_s
  reply = case type
          when "server_info", "SERVER_INFO"
            server_info
          when "ping"
            { "success" => true, "data" => { "status" => "ok" } }
          else
            { "success" => false, "error" => "unsupported_message", "data" => {} }
          end
  id = message["id"]
  reply["id"] = id unless id.nil? || id.to_s.empty?
  reply["timestamp"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
  write_message(reply)
end
''';
}

void clearMacQuarantineAttribute(String path) {
  if (!Platform.isMacOS) {
    return;
  }
  try {
    final library = DynamicLibrary.process();
    final removexattr = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, int)
        >('removexattr');
    final pathPointer = path.toNativeUtf8();
    final namePointer = 'com.apple.quarantine'.toNativeUtf8();
    try {
      removexattr(pathPointer, namePointer, 0);
    } finally {
      malloc.free(pathPointer);
      malloc.free(namePointer);
    }
  } catch (_) {}
}
