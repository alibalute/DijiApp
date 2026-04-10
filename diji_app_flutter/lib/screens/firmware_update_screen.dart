import 'dart:async' show Timer, unawaited;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:diji_app_flutter/ble/ble_bridge.dart';
import 'package:diji_app_flutter/models/firmware_version.dart';
import 'package:diji_app_flutter/services/firmware_version_check.dart';
import 'package:diji_app_flutter/services/wifi_firmware_ota.dart';

/// WiFi OTA: download latest .bin from dijilele.com (internet), BLE starts the instrument AP,
/// then POST to `http://192.168.4.1/api/update`. Same flow and copy as the former Update tab in `qui-skinned.html`.
class FirmwareUpdateScreen extends StatefulWidget {
  const FirmwareUpdateScreen({
    super.key,
    this.initialFirmwareBytes,
    this.initialFirmwareName = 'firmware.bin',
  });

  /// When set (e.g. Chrome web tab downloaded into IndexedDB, then passed via JS bridge).
  final Uint8List? initialFirmwareBytes;
  final String initialFirmwareName;

  @override
  State<FirmwareUpdateScreen> createState() => _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends State<FirmwareUpdateScreen> {
  final BleBridge _ble = BleBridge();

  String? _status;
  bool _busy = false;

  String? _fwCompareMessage;
  bool _fwCompareBusy = false;
  String? _fwCompareLastDeviceKey;

  Uint8List? _firmwareCache;
  String _firmwareCacheName = '';

  static const String _apSsid = 'Dijilele';
  static const String _apPass = 'dijilele123';
  static final Uri _deviceBase = Uri.parse('http://192.168.4.1');

  Timer? _uiTick;

  @override
  void initState() {
    super.initState();
    final init = widget.initialFirmwareBytes;
    if (init != null && init.isNotEmpty) {
      _firmwareCache = Uint8List.fromList(init);
      _firmwareCacheName = widget.initialFirmwareName.isNotEmpty
          ? widget.initialFirmwareName
          : 'firmware.bin';
    }
    _ble.firmwareVersion.addListener(_onBleFirmwareVersion);
    _onBleFirmwareVersion();
    _uiTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiTick?.cancel();
    _ble.firmwareVersion.removeListener(_onBleFirmwareVersion);
    super.dispose();
  }

  void _onBleFirmwareVersion() {
    final v = _ble.firmwareVersion.value;
    if (v == null) {
      if (_fwCompareMessage != null || _fwCompareLastDeviceKey != null) {
        _fwCompareLastDeviceKey = null;
        setState(() {
          _fwCompareMessage = null;
          _fwCompareBusy = false;
        });
      }
      return;
    }
    final key = v.toString();
    if (key == _fwCompareLastDeviceKey || _fwCompareBusy) return;
    unawaited(_compareWithPublished(v, key));
  }

  Future<void> _compareWithPublished(FirmwareVersion device, String key) async {
    setState(() {
      _fwCompareBusy = true;
      _fwCompareMessage = 'Checking published firmware on dijilele.com…';
    });
    try {
      final latest = await FirmwareVersionCheck.fetchLatestOnline();
      if (!mounted) return;
      if (latest == null) {
        setState(() {
          _fwCompareBusy = false;
          _fwCompareLastDeviceKey = key;
          _fwCompareMessage =
              'Could not read latest version from dijilele.com (offline or server not configured). '
              'Expected JSON at ${FirmwareVersionCheck.latestJsonUri} or a line at '
              '${FirmwareVersionCheck.versionTxtUri} (e.g. 2.0.1). Your device: $device.';
        });
        return;
      }
      _fwCompareLastDeviceKey = key;
      final needs = device.isLessThan(latest);
      setState(() {
        _fwCompareBusy = false;
        if (needs) {
          _fwCompareMessage =
              'Update available. Your instrument is $device. Latest published build is $latest '
              '(${FirmwareVersionCheck.binUrlFor(latest).path}). '
              'Tap “Download new version” below while you have internet.';
        } else {
          _fwCompareMessage =
              'Firmware is up to date for published builds ($latest on server; your device $device).';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fwCompareBusy = false;
        _fwCompareLastDeviceKey = key;
        _fwCompareMessage = 'Version check failed: $e';
      });
    }
  }

  Future<void> _setStatus(String? s) async {
    if (!mounted) return;
    setState(() => _status = s);
  }

  Future<void> _alert(String title, String body) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Same order as `qui-skinned.html` Update tab: 1) download, 2) WiFi via BLE, 3) upload.
  Future<void> _downloadNewVersion() async {
    setState(() => _busy = true);
    await _setStatus('Checking latest version on dijilele.com…');
    try {
      final latest = await FirmwareVersionCheck.fetchLatestOnline();
      if (latest == null) {
        await _setStatus('');
        if (!mounted) return;
        await _alert(
          'Firmware',
          'Could not read latest version. Host dijilele-firmware-latest.json or '
          'dijilele-firmware-version.txt on dijilele.com.',
        );
        return;
      }
      _firmwareCacheName =
          'dijilele-${latest.major}-${latest.minor}-${latest.patch}.bin';
      final url = FirmwareVersionCheck.binUrlFor(latest).toString();
      await _setStatus('Downloading $_firmwareCacheName…');
      final bytes = await WifiFirmwareOta.downloadFirmware(url);
      if (!mounted) return;
      setState(() {
        _firmwareCache = bytes;
      });
      await _setStatus(
        'Downloaded ${bytes.length} bytes. Ready to upload after you join Wi‑Fi “$_apSsid”.',
      );
    } catch (e) {
      await _setStatus('');
      if (!mounted) return;
      await _alert('Download failed', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOnDijileleWifi() async {
    if (kIsWeb) {
      await _alert(
        'Turn on Wi‑Fi',
        'This browser page cannot send Bluetooth from Flutter. On the main screen, connect to '
        'the instrument on the Device tab, then use **Start WiFi update (HTTP)** on the first tab.',
      );
      return;
    }
    if (!_ble.isConnected) {
      await _alert(
        'Not connected',
        'Connect to the instrument on the Device tab first.',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await _ble.sendEtarControlMessage(BleBridge.messageWifiOtaServer, 0x01);
      if (!mounted) return;
      await _alert(
        'Wi‑Fi',
        'Find Dijilele on the wifi list of your phone, tablet or computer and connect to it. '
        'The password is "dijilele123"',
      );
      await _setStatus(
        'WiFi command sent. Join “$_apSsid” (password: $_apPass), wait for the page, then tap “Update firmware”.',
      );
    } catch (e) {
      if (!mounted) return;
      await _alert('BLE', 'Could not send command: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateFirmware() async {
    if (_firmwareCache == null || _firmwareCache!.isEmpty) {
      await _alert(
        'Firmware',
        'Download a firmware file first (tap “Download new version”).',
      );
      return;
    }
    setState(() => _busy = true);
    await _setStatus('Checking instrument at http://192.168.4.1 …');
    try {
      if (!await WifiFirmwareOta.probeDevice(_deviceBase)) {
        await _setStatus(
          'Instrument not reachable (GET /api/debug). Join Wi‑Fi “$_apSsid” (password: $_apPass), then try again.',
        );
        if (!mounted) return;
        await _alert(
          'Instrument not reachable',
          'Could not reach http://192.168.4.1 from this app.\n\n'
          'Join Wi‑Fi “$_apSsid” (password: $_apPass), wait a few seconds, then tap “Update firmware” again. '
          'Or open http://192.168.4.1 in a browser tab and upload the .bin there.',
        );
        return;
      }
      await _setStatus('Uploading ${_firmwareCache!.length} bytes…');
      final resp = await WifiFirmwareOta.uploadFirmware(
        deviceBase: _deviceBase,
        firmwareBytes: _firmwareCache!,
        filename: _firmwareCacheName.isNotEmpty ? _firmwareCacheName : 'firmware.bin',
      );
      final bodyText = resp.body;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final tail = bodyText.length < 400 ? bodyText : '';
        await _setStatus(
          'Update sent (HTTP ${resp.statusCode}). The instrument should reboot.\n$tail',
        );
      } else {
        final short = bodyText.length > 500 ? '${bodyText.substring(0, 500)}…' : bodyText;
        await _setStatus(
          'Upload returned HTTP ${resp.statusCode}. $short',
        );
      }
    } catch (e) {
      await _setStatus(
        'Upload failed: $e\n'
        'Join Wi‑Fi “$_apSsid” (password: $_apPass), then try again.\n\n'
        'If you are already on “$_apSsid” Wi‑Fi, the connection may be blocked until the '
        'instrument firmware adds CORS headers, or open http://192.168.4.1 in a browser tab '
        'and upload the .bin from that page.',
      );
      if (!mounted) return;
      await _alert(
        'Could not reach the instrument',
        'Could not reach http://192.168.4.1 from this app.\n\n'
        '1) Join Wi‑Fi “$_apSsid” (password: $_apPass).\n'
        '2) Reflash with firmware where /api/debug sends CORS (latest WebServer + http_ota_cors).\n'
        '3) Or upload from a browser tab opened directly at http://192.168.4.1.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Native app: BLE lives in [BleBridge]. Web: BLE is only in the embedded HTML (Web Bluetooth);
  /// Flutter cannot send the Wi‑Fi OTA packet from here, but the button stays tappable to explain.
  VoidCallback? get _onTurnOnWifi {
    if (_busy) return null;
    if (kIsWeb) return _turnOnDijileleWifi;
    return _ble.isConnected ? _turnOnDijileleWifi : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Firmware update (WiFi)'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Download while online. Turn on the instrument Wi‑Fi, join network “$_apSsid” '
              '(password $_apPass), then upload the file to the instrument.',
              style: TextStyle(height: 1.45),
            ),
            const SizedBox(height: 12),
            Text(
              'Steps: (1) Download new version — (2) Turn on Dijilele\'s wifi — '
              '(3) Connect your phone or computer to “$_apSsid” — (4) Update firmware.',
              style: TextStyle(
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 12),
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'In Chrome web, Bluetooth is only available from the main HTML UI. '
                    'Use **Start WiFi update (HTTP)** there after connecting; download the .bin here, '
                    'then upload after joining the instrument Wi‑Fi.',
                    style: TextStyle(
                      height: 1.35,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
            if (_fwCompareBusy || _fwCompareMessage != null) ...[
              const SizedBox(height: 12),
              Card(
                color: (_fwCompareMessage != null &&
                        _fwCompareMessage!.startsWith('Update available'))
                    ? Theme.of(context).colorScheme.errorContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_fwCompareBusy)
                        const Padding(
                          padding: EdgeInsets.only(right: 12, top: 2),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          _fwCompareMessage ?? '…',
                          style: TextStyle(
                            height: 1.35,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _downloadNewVersion,
              icon: const Icon(Icons.download),
              label: const Text('Download new version'),
            ),
            if (_firmwareCache != null) ...[
              const SizedBox(height: 8),
              Text(
                _firmwareCacheName.isNotEmpty
                    ? _firmwareCacheName
                    : '${_firmwareCache!.length} bytes ready',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _onTurnOnWifi,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Turn on Dijilele\'s wifi'),
            ),
            if (kIsWeb || !_ble.isConnected) ...[
              const SizedBox(height: 6),
              Text(
                kIsWeb
                    ? 'Chrome cannot use Flutter’s Bluetooth stack here. On the main screen, connect with Web Bluetooth, then tap Start WiFi update (HTTP) on the first tab (same BLE command as this button on phone).'
                    : 'Connect the instrument on the Device tab first.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _updateFirmware,
              icon: const Icon(Icons.system_update_alt),
              label: const Text('Update firmware'),
            ),
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_status != null) ...[
              const SizedBox(height: 24),
              Text(
                _status!,
                style: const TextStyle(height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
