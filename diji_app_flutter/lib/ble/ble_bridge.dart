import 'dart:convert';
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

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  void Function(String base64)? _onNotification;
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
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) return null;

    await _requestBluetoothPermission();

    const scanDuration = Duration(seconds: 15);
    final Map<String, ({BluetoothDevice device, String name})> seen = {};

    try {
      // Scan without service filter so we find devices that don't advertise the
      // service UUID (many devices don't advertise it; filtering yields no results on some Android/iOS).
      await FlutterBluePlus.startScan(timeout: scanDuration);

      // Collect results until timeout. scanResults emits the current list on each update;
      // first emission is often empty, so we must listen for the full duration.
      await FlutterBluePlus.scanResults
          .map((List<ScanResult> list) {
            for (final r in list) {
              final id = r.device.remoteId.str;
              if (seen.containsKey(id)) continue;
              final name = r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : (r.device.platformName.isNotEmpty ? r.device.platformName : '');
              seen[id] = (device: r.device, name: name.isNotEmpty ? name : 'Dijilele');
            }
            return null;
          })
          .drain()
          .timeout(scanDuration, onTimeout: () {});

      await FlutterBluePlus.stopScan();
    } catch (_) {
      await FlutterBluePlus.stopScan();
    }

    if (seen.isEmpty) return null;

    // Prefer device whose name contains "Dijilele" (case-insensitive), otherwise pick first.
    final list = seen.entries.toList();
    final dijiele = list.where((e) => e.value.name.toLowerCase().contains('dijiele')).toList();
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
    if (c == null) return;
    try {
      final bytes = base64Decode(base64);
      await c.write(bytes, withoutResponse: false);
    } catch (_) {}
  }

  void startNotifications(void Function(String base64) onData) {
    final c = _characteristic;
    if (c == null) return;
    _onNotification = onData;
    c.lastValueStream.listen((value) {
      if (value.isNotEmpty && _onNotification != null) {
        final b64 = base64Encode(value);
        _onNotification!(b64);
      }
    });
    c.setNotifyValue(true);
  }

  /// Disconnect from the current device. Use this when the user taps Disconnect
  /// in the WebView; the bridge remains usable for reconnection.
  void disconnect() {
    _device?.disconnect();
    _device = null;
    _characteristic = null;
    _onNotification = null;
  }

  void dispose() {
    disconnect();
  }
}
