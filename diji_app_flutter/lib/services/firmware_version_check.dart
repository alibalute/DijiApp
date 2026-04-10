import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:diji_app_flutter/models/firmware_version.dart';

/// Online “latest” version for comparison with the instrument (BLE telemetry).
///
/// Host one of these on **https://dijilele.com** (CORS must allow GET from your app origin):
/// - [latestJsonUri]: `{ "major": 2, "minor": 0, "patch": 4 }` or `"version": "2.0.4"` or `"version": [2,0,4]`
/// - [versionTxtUri]: single line `2.0.4`
///
/// The firmware file is expected at `https://dijilele.com/dijilele-<major>-<minor>-<patch>.bin`.
class FirmwareVersionCheck {
  FirmwareVersionCheck._();

  static const String _base = 'https://dijilele.com';

  static Uri get latestJsonUri => Uri.parse('$_base/dijilele-firmware-latest.json');
  static Uri get versionTxtUri => Uri.parse('$_base/dijilele-firmware-version.txt');

  static Uri binUrlFor(FirmwareVersion v) =>
      Uri.parse('$_base/dijilele-${v.major}-${v.minor}-${v.patch}.bin');

  static FirmwareVersion? _parseJsonMap(Map<String, dynamic> j) {
    final m = j['major'];
    final mi = j['minor'];
    final p = j['patch'];
    if (m is int && mi is int && p is int) {
      return FirmwareVersion(m, mi, p);
    }
    final vs = j['version'];
    if (vs is String) return FirmwareVersion.tryParse(vs);
    if (vs is List && vs.length >= 3) {
      final a = vs[0];
      final b = vs[1];
      final c = vs[2];
      if (a is int && b is int && c is int) {
        return FirmwareVersion(a, b, c);
      }
    }
    return null;
  }

  /// Returns null if the server did not return a usable version (offline, 404, bad format).
  static Future<FirmwareVersion?> fetchLatestOnline() async {
    try {
      final r = await http.get(latestJsonUri).timeout(const Duration(seconds: 10));
      if (r.statusCode >= 200 && r.statusCode < 300 && r.body.isNotEmpty) {
        final decoded = jsonDecode(r.body);
        if (decoded is Map) {
          final v = _parseJsonMap(Map<String, dynamic>.from(decoded));
          if (v != null) return v;
        }
      }
    } catch (_) {
      /* try txt */
    }
    try {
      final r = await http.get(versionTxtUri).timeout(const Duration(seconds: 10));
      if (r.statusCode >= 200 && r.statusCode < 300 && r.body.isNotEmpty) {
        return FirmwareVersion.tryParse(r.body);
      }
    } catch (_) {
      /* null */
    }
    return null;
  }
}
