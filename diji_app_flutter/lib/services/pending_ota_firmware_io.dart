import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Persists pending Wi‑Fi OTA .bin outside the WebView (WKWebView IndexedDB is unreliable for large blobs).
/// Uses [Directory.systemTemp] only — avoids `path_provider`, which pulled native toolchains that broke iOS codesign
/// (`resource fork … not allowed` on `objective_c.framework` in some Xcode setups).
class PendingOtaFirmware {
  PendingOtaFirmware._();

  static const _binName = 'diji_pending_ota_firmware.bin';
  static const _txtName = 'diji_pending_ota_firmware_name.txt';

  static String get _base => Directory.systemTemp.path;

  static File _binFileSync() => File('$_base/$_binName');

  static File _nameFileSync() => File('$_base/$_txtName');

  static Future<void> save({required String name, required List<int> bytes}) async {
    final bin = _binFileSync();
    final nf = _nameFileSync();
    await nf.writeAsString(name, flush: true);
    await bin.writeAsBytes(bytes, flush: true);
    debugPrint('PendingOtaFirmware: saved ${bytes.length} bytes as $name');
  }

  static Future<void> clear() async {
    try {
      final f = _binFileSync();
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      final f = _nameFileSync();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Lightweight check for UI (no base64).
  static Future<Map<String, dynamic>?> metadata() async {
    final bin = _binFileSync();
    if (!await bin.exists()) return null;
    final len = await bin.length();
    if (len == 0) return null;
    var name = 'firmware.bin';
    final nf = _nameFileSync();
    if (await nf.exists()) {
      try {
        final t = (await nf.readAsString()).trim();
        if (t.isNotEmpty) name = t;
      } catch (_) {}
    }
    return {'has': true, 'name': name, 'size': len};
  }

  /// Returns `{ name, b64 }` for the WebView to postMessage into the instrument iframe.
  static Future<Map<String, String>?> readAsBase64Map() async {
    final bin = _binFileSync();
    if (!await bin.exists()) return null;
    final raw = await bin.readAsBytes();
    if (raw.isEmpty) return null;
    final nf = _nameFileSync();
    var name = 'firmware.bin';
    if (await nf.exists()) {
      try {
        final t = (await nf.readAsString()).trim();
        if (t.isNotEmpty) name = t;
      } catch (_) {}
    }
    return {'name': name, 'b64': base64Encode(raw)};
  }
}
