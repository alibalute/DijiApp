import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:diji_app_flutter/services/pending_ota_firmware.dart';
import 'package:diji_app_flutter/services/wifi_firmware_ota.dart';

/// Registers JS handlers so OTA .bin lives in app documents (not WKWebView IndexedDB).
void registerOtaFirmwareJavaScriptHandlers(InAppWebViewController controller) {
  if (kIsWeb) return;
  try {
    controller.addJavaScriptHandler(
      handlerName: 'nativeDownloadOtaFirmware',
      callback: (args) async {
        final url = args.isNotEmpty ? args[0]?.toString() : null;
        final name = (args.length > 1 ? args[1]?.toString() : null) ?? 'firmware.bin';
        if (url == null || url.isEmpty) {
          return {'ok': false, 'error': 'no url'};
        }
        try {
          final bytes = await WifiFirmwareOta.downloadFirmware(url);
          await PendingOtaFirmware.save(name: name, bytes: bytes);
          return {'ok': true, 'name': name, 'size': bytes.length};
        } catch (e) {
          debugPrint('nativeDownloadOtaFirmware: $e');
          return {'ok': false, 'error': e.toString()};
        }
      },
    );
  } catch (_) {}
  try {
    controller.addJavaScriptHandler(
      handlerName: 'otaPendingFirmwareMeta',
      callback: (_) async {
        try {
          final m = await PendingOtaFirmware.metadata();
          if (m == null) return {'has': false};
          return m;
        } catch (e) {
          debugPrint('otaPendingFirmwareMeta: $e');
          return {'has': false};
        }
      },
    );
  } catch (_) {}
  try {
    controller.addJavaScriptHandler(
      handlerName: 'otaGetPendingFirmware',
      callback: (_) async {
        try {
          final m = await PendingOtaFirmware.readAsBase64Map();
          if (m == null) return null;
          return m;
        } catch (e) {
          debugPrint('otaGetPendingFirmware: $e');
          return null;
        }
      },
    );
  } catch (_) {}
}
