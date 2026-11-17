abstract class LocalAppBridgeStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryLocalAppBridgeStorage implements LocalAppBridgeStorage {
  MemoryLocalAppBridgeStorage({Map<String, String>? initialValues})
    : _values = Map<String, String>.from(initialValues ?? const <String, String>{});

  final Map<String, String> _values;

  Map<String, String> get snapshot => Map<String, String>.from(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
