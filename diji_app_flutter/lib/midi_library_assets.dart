import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Bundled MIDI files under [kManifestPath] and paths listed in the manifest.
class MidiLibraryAssets {
  MidiLibraryAssets._();

  static const String kManifestPath = 'assets/midi_library/midi_manifest.json';

  static Future<String> readManifestJson() async {
    return rootBundle.loadString(kManifestPath);
  }

  /// Only assets under `assets/midi_library/` with a .mid/.midi extension.
  static bool isAllowedAssetKey(String key) {
    final k = key.trim();
    if (k.isEmpty || k.contains('..')) return false;
    final lower = k.toLowerCase();
    if (!lower.endsWith('.mid') && !lower.endsWith('.midi')) return false;
    return lower.startsWith('assets/midi_library/');
  }

  static Future<String> loadAssetAsBase64(String assetKey) async {
    if (!isAllowedAssetKey(assetKey)) {
      throw ArgumentError.value(
          assetKey, 'assetKey', 'not an allowed bundled MIDI path');
    }
    final bd = await rootBundle.load(assetKey);
    final u8 = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    return base64Encode(u8);
  }

  static String basename(String assetKey) {
    final i = assetKey.lastIndexOf('/');
    return i >= 0 ? assetKey.substring(i + 1) : assetKey;
  }
}
