import 'dart:convert';
import 'dart:typed_data';

const int kLocalAppBridgeNativeMessageMaxBytes = 1024 * 1024;

class LocalAppBridgeNativeMessagingCodec {
  static Uint8List encode(Map<String, Object?> message) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    if (payload.length > kLocalAppBridgeNativeMessageMaxBytes) {
      throw ArgumentError.value(
        payload.length,
        'message',
        'Native messaging payload exceeds $kLocalAppBridgeNativeMessageMaxBytes bytes.',
      );
    }
    final header = ByteData(4)..setUint32(0, payload.length, Endian.little);
    final framed = Uint8List(4 + payload.length);
    framed.setRange(0, 4, header.buffer.asUint8List());
    framed.setRange(4, framed.length, payload);
    return framed;
  }

  static Map<String, dynamic> decode(List<int> messageBytes) {
    if (messageBytes.length > kLocalAppBridgeNativeMessageMaxBytes) {
      throw FormatException('Native messaging payload is too large.');
    }
    final decoded = jsonDecode(utf8.decode(messageBytes));
    if (decoded is! Map) {
      throw const FormatException('Native messaging payload must be a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

class LocalAppBridgeNativeMessagingReader {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int? _expectedLength;

  Iterable<Map<String, dynamic>> add(List<int> chunk) sync* {
    if (chunk.isNotEmpty) {
      _buffer.add(chunk);
    }
    while (true) {
      final available = _takeSnapshot();
      if (_expectedLength == null) {
        if (available.length < 4) {
          _buffer.add(available);
          return;
        }
        final header = ByteData.sublistView(Uint8List.fromList(available.sublist(0, 4)));
        _expectedLength = header.getUint32(0, Endian.little);
        if (_expectedLength! <= 0 || _expectedLength! > kLocalAppBridgeNativeMessageMaxBytes) {
          throw FormatException('Invalid native messaging frame length: $_expectedLength');
        }
        _buffer.add(available.sublist(4));
        continue;
      }
      if (available.length < _expectedLength!) {
        _buffer.add(available);
        return;
      }
      final message = available.sublist(0, _expectedLength!);
      final rest = available.sublist(_expectedLength!);
      _expectedLength = null;
      if (rest.isNotEmpty) {
        _buffer.add(rest);
      }
      yield LocalAppBridgeNativeMessagingCodec.decode(message);
    }
  }

  Uint8List _takeSnapshot() {
    if (_buffer.isEmpty) {
      return Uint8List(0);
    }
    return _buffer.takeBytes();
  }
}
