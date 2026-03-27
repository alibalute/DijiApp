import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class DeviceResult {
  final String id;
  final String name;
  DeviceResult({required this.id, required this.name});
}

class BleBridge {
  static const String serviceUuid = '03b80e5a-ede8-4b33-a751-6ce34ec4c700';
  static const String charUuid = '7772e5db-3868-4112-a1a9-f2669d106bf3';

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  void Function(String base64)? _onNotification;
  StreamSubscription<List<int>>? _notificationSubscription;
  final Map<String, BluetoothDevice> _scannedDevices = {};

  /// Request Bluetooth permission. Android 12+ needs BLUETOOTH_SCAN/CONNECT; Android 6–11 needs BLUETOOTH + location.
  Future<void> _requestBluetoothPermission() async {
    // Android 12+ (API 31+): BLUETOOTH_SCAN and BLUETOOTH_CONNECT (no-op on Android 7 / API 24)
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    // Android 6–11 and Android 7: BLUETOOTH + ACCESS_FINE_LOCATION for BLE scan
    await Permission.bluetooth.request();
    await Permission.locationWhenInUse.request();
  }

  Future<DeviceResult?> requestDevice() async {
    // Request OS permissions first. On iOS the first adapterState emission is often
    // unknown/unauthorized until the user allows Bluetooth — if we checked .first
    // before permission + before 'on', the first tap returned null (second tap worked).
    await _requestBluetoothPermission();

    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .timeout(const Duration(seconds: 12))
          .first;
    } catch (e) {
      debugPrint('BLE requestDevice: adapter not on: $e');
      return null;
    }

    /// Hard cap (same as before). We usually finish much earlier.
    const maxScan = Duration(seconds: 15);
    /// iOS: CoreBluetooth batches scan updates; shorter settle is enough.
    final settleAfterFirstDevice =
        _isIOS ? const Duration(milliseconds: 250) : const Duration(milliseconds: 800);

    final Map<String, ({BluetoothDevice device, String name})> seen = {};
    final completer = Completer<void>();
    Timer? settleTimer;
    StreamSubscription<List<ScanResult>>? sub;

    bool nameHasDijiele(String name) => name.toLowerCase().contains('dijiele');

    bool hasPreferredName() => seen.values.any((e) => nameHasDijiele(e.name));

    /// iOS: peripherals already known to the OS (e.g. previously paired) appear
    /// here without waiting for an active scan (flutter_blue_plus documents this path).
    if (_isIOS) {
      try {
        final sys = await FlutterBluePlus.systemDevices([Guid(serviceUuid)]);
        for (final d in sys) {
          final id = d.remoteId.str;
          if (seen.containsKey(id)) continue;
          final name = d.platformName.isNotEmpty ? d.platformName : 'Dijilele';
          seen[id] = (device: d, name: name);
        }
        if (seen.isNotEmpty) {
          final list = seen.entries.toList();
          final dijiele =
              list.where((e) => nameHasDijiele(e.value.name)).toList();
          final entry = dijiele.isNotEmpty ? dijiele.first : list.first;
          final d = entry.value.device;
          _scannedDevices[d.remoteId.str] = d;
          return DeviceResult(id: d.remoteId.str, name: entry.value.name);
        }
      } catch (e) {
        debugPrint('BLE iOS systemDevices: $e');
      }
    }

    void merge(List<ScanResult> list) {
      for (final r in list) {
        final id = r.device.remoteId.str;
        if (seen.containsKey(id)) continue;
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty ? r.device.platformName : '');
        seen[id] = (device: r.device, name: name.isNotEmpty ? name : 'Dijilele');
      }
    }

    try {
      // Scan without service filter so we find devices that don't advertise the
      // service UUID (many devices don't advertise it; filtering yields no results on some Android/iOS).
      // iOS: oneByOne surfaces each advertisement sooner (helps first scan result).
      await FlutterBluePlus.startScan(
        timeout: maxScan,
        oneByOne: _isIOS,
      );

      sub = FlutterBluePlus.scanResults.listen((List<ScanResult> list) {
        merge(list);
        if (completer.isCompleted) return;
        if (hasPreferredName()) {
          settleTimer?.cancel();
          completer.complete();
          return;
        }
        if (seen.isNotEmpty) {
          settleTimer ??= Timer(settleAfterFirstDevice, () {
            if (!completer.isCompleted) completer.complete();
          });
        }
      });

      await Future.any<void>([
        completer.future,
        Future<void>.delayed(maxScan),
      ]);

      settleTimer?.cancel();
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    } catch (_) {
      settleTimer?.cancel();
      await sub?.cancel();
      await FlutterBluePlus.stopScan();
    }

    if (seen.isEmpty) return null;

    // Prefer device whose name contains "Dijilele" (case-insensitive), otherwise pick first.
    final list = seen.entries.toList();
    final dijiele = list.where((e) => nameHasDijiele(e.value.name)).toList();
    final entry = dijiele.isNotEmpty ? dijiele.first : list.first;

    final d = entry.value.device;
    _scannedDevices[d.remoteId.str] = d;
    return DeviceResult(id: d.remoteId.str, name: entry.value.name);
  }

  /// Normalize BLE device id for lookup (lowercase, no separators).
  static String _normalizeId(String id) {
    return id.toLowerCase().replaceAll(RegExp(r'[-:]'), '');
  }

  Future<bool> connect(String deviceId) async {
    try {
      await _requestBluetoothPermission();

      BluetoothDevice? target = _scannedDevices[deviceId];
      if (target == null) {
        final normalized = _normalizeId(deviceId);
        for (final e in _scannedDevices.entries) {
          if (_normalizeId(e.key) == normalized) {
            target = e.value;
            break;
          }
        }
      }
      if (target == null) {
        final devices = await FlutterBluePlus.systemDevices([]);
        for (final d in devices) {
          if (_normalizeId(d.remoteId.str) == _normalizeId(deviceId)) {
            target = d;
            break;
          }
        }
      }
      target ??= BluetoothDevice(remoteId: DeviceIdentifier(deviceId));

      await target.connect(timeout: const Duration(seconds: 25));
      _device = target;

      final services = await target.discoverServices();
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == serviceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid.toString().toLowerCase() == charUuid) {
              _characteristic = c;
              debugPrint(
                'BLE MIDI characteristic properties: ${c.properties}',
              );
              break;
            }
          }
          break;
        }
      }
      return _characteristic != null;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> writeValueBase64(String base64) async {
    final c = _characteristic;
    if (c == null) {
      debugPrint('BLE write skipped: no characteristic (connect first)');
      return;
    }
    try {
      final bytes = base64Decode(base64);
      final p = c.properties;

      Future<void> writeNoResp() => c.write(bytes, withoutResponse: true);
      Future<void> writeWithResp() => c.write(bytes, withoutResponse: false);

      // MIDI / firmware exposes WRITE + WRITE_NR. Prefer WRITE_NR (low latency).
      // iOS sometimes mis-reports flags vs Android; retry the other mode on failure.
      if (p.writeWithoutResponse) {
        try {
          await writeNoResp();
          return;
        } catch (e) {
          debugPrint('BLE write withoutResponse failed, retrying with response: $e');
        }
      }
      if (p.write) {
        try {
          await writeWithResp();
          return;
        } catch (e) {
          debugPrint('BLE write with response failed: $e');
        }
      }
      // No flags or both attempts failed: try both modes (covers sparse iOS props).
      try {
        await writeNoResp();
      } catch (e) {
        debugPrint('BLE write fallback withoutResponse: $e');
        await writeWithResp();
      }
    } catch (e, st) {
      debugPrint('BLE write failed: $e\n$st');
    }
  }

  /// Subscribe to device indications/notifications. Awaits CCCD on iOS before data flows reliably.
  Future<void> startNotifications(void Function(String base64) onData) async {
    final c = _characteristic;
    if (c == null) return;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _onNotification = onData;
    _notificationSubscription = c.onValueReceived.listen((value) {
      if (value.isNotEmpty && _onNotification != null) {
        final b64 = base64Encode(value);
        _onNotification!(b64);
      }
    });
    try {
      await c.setNotifyValue(true);
    } catch (e, st) {
      debugPrint('BLE setNotifyValue failed: $e\n$st');
    }
  }

  /// Disconnect from the current device. Use this when the user taps Disconnect
  /// in the WebView; the bridge remains usable for reconnection.
  void disconnect() {
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _device?.disconnect();
    _device = null;
    _characteristic = null;
    _onNotification = null;
  }

  void dispose() {
    disconnect();
  }
}
