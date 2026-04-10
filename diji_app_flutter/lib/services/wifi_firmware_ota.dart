import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// HTTP helpers for Dijilele ESP WiFi OTA ([WebServer.cpp]: POST `/api/update`, field `firmware`).
class WifiFirmwareOta {
  WifiFirmwareOta._();

  static String joinPath(String base, String path) {
    final b = base.trim().replaceAll(RegExp(r'/+$'), '');
    final p = path.startsWith('/') ? path.substring(1) : path;
    return '$b/$p';
  }

  static Uri normalizeDeviceBase(String input) {
    var s = input.trim();
    if (s.isEmpty) {
      return Uri.parse('http://192.168.4.1');
    }
    if (!s.contains('://')) {
      s = 'http://$s';
    }
    return Uri.parse(s);
  }

  /// Returns true if the instrument HTTP server responds (GET `/api/debug`).
  static Future<bool> probeDevice(Uri deviceBase) async {
    final uri = Uri.parse(joinPath(deviceBase.toString(), 'api/debug'));
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<Uint8List> downloadFirmware(String url) async {
    final uri = Uri.parse(url.trim());
    final resp = await http.get(uri).timeout(const Duration(minutes: 5));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Download failed: HTTP ${resp.statusCode}');
    }
    if (resp.bodyBytes.isEmpty) {
      throw Exception('Downloaded file is empty');
    }
    return Uint8List.fromList(resp.bodyBytes);
  }

  /// Multipart upload matching firmware [FirmwareUpdater.cpp] (`name="firmware"`).
  static Future<http.Response> uploadFirmware({
    required Uri deviceBase,
    required Uint8List firmwareBytes,
    String filename = 'firmware.bin',
  }) async {
    final uploadUri = Uri.parse(joinPath(deviceBase.toString(), 'api/update'));
    final req = http.MultipartRequest('POST', uploadUri);
    req.files.add(
      http.MultipartFile.fromBytes(
        'firmware',
        firmwareBytes,
        filename: filename,
      ),
    );
    final streamed = await req.send().timeout(const Duration(minutes: 15));
    return http.Response.fromStream(streamed);
  }
}
