/// Web / non-IO: no native pending firmware file.
class PendingOtaFirmware {
  PendingOtaFirmware._();

  static Future<void> save({required String name, required List<int> bytes}) async {}

  static Future<void> clear() async {}

  static Future<Map<String, dynamic>?> metadata() async => null;

  static Future<Map<String, String>?> readAsBase64Map() async => null;
}
