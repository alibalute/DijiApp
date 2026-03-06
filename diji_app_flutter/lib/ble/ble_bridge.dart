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

  /// Request Bluetooth permission. On iOS the system dialog may appear when BLE is first used.
  Future<void> _requestBluetoothPermission() async {
    await Permission.bluetooth.request();
  }

  Future<DeviceResult?> requestDevice() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) return null;

    await _requestBluetoothPermission();

    try {
      // Scan without service filter so we find devices that don't advertise the
      // eTar service UUID (iOS often returns no devices when filtering by service).
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
      );
      BluetoothDevice? found;
      await for (final scanResult in FlutterBluePlus.scanResults) {
        for (final r in scanResult) {
          if (r.device.platformName.isNotEmpty || r.advertisementData.advName.isNotEmpty) {
            found = r.device;
            break;
          }
        }
        if (found != null) break;
        if (scanResult.isNotEmpty) {
          found = scanResult.first.device;
          break;
        }
      }
      await FlutterBluePlus.stopScan();
      if (found != null) {
        _scannedDevices[found.remoteId.str] = found;
        final name = found.platformName.isNotEmpty ? found.platformName : 'eTar';
        return DeviceResult(id: found.remoteId.str, name: name);
      }
    } catch (e) {
      await FlutterBluePlus.stopScan();
    }
    return null;
  }

  Future<bool> connect(String deviceId) async {
    try {
      BluetoothDevice? target = _scannedDevices[deviceId];
      if (target == null) {
        final devices = await FlutterBluePlus.systemDevices([]);
        for (final d in devices) {
          if (d.remoteId.str == deviceId) {
            target = d;
            break;
          }
        }
      }
      target ??= BluetoothDevice(remoteId: DeviceIdentifier(deviceId));
      await target.connect();
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
      return false;
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
