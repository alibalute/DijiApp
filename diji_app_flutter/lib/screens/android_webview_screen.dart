import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show EventChannel, MethodCall, MethodChannel, PlatformException, rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:diji_app_flutter/ble/ble_bridge.dart';
import 'package:diji_app_flutter/midi_library_assets.dart';
import 'package:diji_app_flutter/screens/firmware_update_screen.dart';
import 'package:diji_app_flutter/services/wifi_firmware_ota.dart';
import 'package:diji_app_flutter/webview_ota_handlers.dart';
import 'package:diji_app_flutter/webview_external_navigation.dart';
import 'package:diji_app_flutter/widgets/top_links_strip.dart';

/// Android-only WebView. Loads the same asset URL as iOS so touch/gesture behavior matches.
class AndroidWebViewScreen extends StatefulWidget {
  const AndroidWebViewScreen({super.key});

  @override
  State<AndroidWebViewScreen> createState() => _AndroidWebViewScreenState();
}

class _AndroidWebViewScreenState extends State<AndroidWebViewScreen> {
  static const _nativeUsbSynth =
      MethodChannel('com.example.diji_app_flutter/native_usb_synth');

  final BleBridge _bleBridge = BleBridge();

  /// Serves Flutter assets over http://127.0.0.1 so AudioWorklet / WASM work (they fail on file:// WebView).
  final InAppLocalhostServer _assetServer =
      InAppLocalhostServer(port: 8787, documentRoot: 'assets');
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _error;
  String? _logoDataUri;

  /// Set after [_assetServer] starts; WebView loads [qui-skinned.html] from this origin.
  String? _webEntryUrl;

  /// Same workaround as [WebScreen]: on Android, [onLoadStop] can be late; never block UI forever.
  static const Duration _maxSpinnerDuration = Duration(milliseconds: 2500);

  static const MethodChannel _usbMidiMethod =
      MethodChannel('com.example.diji_app_flutter/usb_midi');
  static const EventChannel _usbMidiEvents =
      EventChannel('com.example.diji_app_flutter/usb_midi_stream');

  StreamSubscription<dynamic>? _usbMidiSub;

  static const String _bridgeScript = r'''
(function() {
  window.__dijiNativeUsbMidi = true;
  window.__dijiNativeSoundfontPicker = true;
  if (typeof window.AndroidBLE !== 'undefined') return;
  window.AndroidBLE = {
    requestDevice: function(id) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('ble', JSON.stringify({ method: 'requestDevice', callbackId: id }));
      }
    },
    connect: function(deviceId, cid) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('ble', JSON.stringify({ method: 'connect', deviceId: deviceId, callbackId: cid }));
      }
    },
    writeValueBase64: function(b64) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('ble', JSON.stringify({ method: 'writeValueBase64', base64: b64 }));
      }
    },
    startNotifications: function() {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('ble', JSON.stringify({ method: 'startNotifications' }));
      }
    },
    disconnect: function() {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('ble', JSON.stringify({ method: 'disconnect' }));
      }
    }
  };
})();
''';

  Future<void> _onBleMessage(String jsonStr) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final method = map['method'] as String?;
      switch (method) {
        case 'requestDevice':
          final rawId = map['callbackId'];
          final callbackId =
              rawId is int ? rawId : (rawId is num ? rawId.toInt() : null);
          if (callbackId != null) {
            final result = await _bleBridge.requestDevice();
            if (result != null) {
              final deviceJson =
                  jsonEncode({'id': result.id, 'name': result.name});
              final escaped =
                  deviceJson.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
              _runJs(
                  controller, "window._bleResolve($callbackId, '$escaped');");
            } else {
              _runJs(controller,
                  "window._bleReject($callbackId, 'No device selected');");
            }
          }
          break;
        case 'connect':
          final deviceId = map['deviceId'] as String?;
          final rawCid = map['callbackId'];
          final callbackId =
              rawCid is int ? rawCid : (rawCid is num ? rawCid.toInt() : null);
          if (deviceId != null && callbackId != null) {
            try {
              final ok = await _bleBridge.connect(deviceId);
              if (ok) {
                _runJs(controller, "window._bleOnConnect($callbackId);");
              } else {
                _runJs(controller,
                    "window._bleReject($callbackId, 'Service or characteristic not found');");
              }
            } catch (e) {
              final msg =
                  e.toString().replaceAll(r'\', r'\\').replaceAll("'", r"\'");
              _runJs(controller, "window._bleReject($callbackId, '$msg');");
            }
          }
          break;
        case 'writeValueBase64':
          final base64 = map['base64'] as String?;
          if (base64 != null) await _bleBridge.writeValueBase64(base64);
          break;
        case 'startNotifications':
          await _bleBridge.startNotifications((base64) {
            // Base64 alphabet is safe inside single-quoted JS; avoid jsonEncode + extra allocations per packet.
            controller.evaluateJavascript(
              source:
                  "try{if(window._bleOnNotification)window._bleOnNotification('$base64');}catch(e){}",
            );
          });
          break;
        case 'disconnect':
          _bleBridge.disconnect();
          break;
      }
    } catch (e, st) {
      debugPrint('BLE bridge error: $e\n$st');
      rethrow;
    }
  }

  void _onUsbMidiBytes(dynamic data) {
    final controller = _controller;
    if (controller == null) {
      debugPrint(
          'USB MIDI: dropped packet (WebView controller null), type=${data.runtimeType}');
      return;
    }
    final Uint8List bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List) {
      bytes = Uint8List.fromList(
        data.map((e) {
          if (e is int) return e;
          if (e is num) return e.toInt();
          return 0;
        }).toList(),
      );
    } else {
      debugPrint(
          'USB MIDI: unexpected EventChannel payload type=${data.runtimeType} value=$data');
      return;
    }
    if (bytes.isEmpty) return;
    // Native [UsbMidiBridge] already coalesces per main-thread post; avoid Dart-side delay here —
    // a debounce timer can starve the WebView if MIDI clock / CC keeps resetting the timer.
    final b64 = base64Encode(bytes);
    final safe = b64.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    _runJs(
      controller,
      "try{if(window._nativeUsbMidiMessage)window._nativeUsbMidiMessage('$safe');}catch(e){}",
    );
  }

  Future<void> _onUsbMidiControlMessage(String jsonStr) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final action = map['action'] as String?;
      if (action == 'start') {
        try {
          final dynamic n = await _usbMidiMethod.invokeMethod<dynamic>('start');
          final count = n is int ? n : (n is num ? n.toInt() : 0);
          _runJs(controller, 'window._usbMidiNativeStarted(true, $count);');
          _scheduleUsbMidiPortPoll(controller);
        } on PlatformException catch (e) {
          final msg = (e.message ?? e.code)
              .replaceAll(r'\', r'\\')
              .replaceAll("'", r"\'");
          _runJs(controller, "window._usbMidiNativeStarted(false, '$msg');");
        } catch (e) {
          final msg =
              e.toString().replaceAll(r'\', r'\\').replaceAll("'", r"\'");
          _runJs(controller, "window._usbMidiNativeStarted(false, '$msg');");
        }
      } else if (action == 'stop') {
        try {
          await _usbMidiMethod.invokeMethod<void>('stop');
        } catch (_) {}
        _runJs(controller,
            'try{if(window._usbMidiNativeStopped)window._usbMidiNativeStopped();}catch(e){}');
      }
    } catch (e) {
      debugPrint('USB MIDI handler: $e');
    }
  }

  void _runJs(InAppWebViewController c, String js) {
    c.evaluateJavascript(source: js);
  }

  /// When BLE drops without the user tapping Disconnect (native link lost).
  void _notifyBleDisconnectedUi() {
    final c = _controller;
    if (c == null || !mounted) return;
    c.evaluateJavascript(
      source:
          "try{if(window.__dijiOnBleDisconnected)window.__dijiOnBleDisconnected();}catch(e){}",
    );
  }

  /// WebView `<input type="file">` on Android often opens the photo gallery; use Storage Access Framework via file_picker.
  ///
  /// Do not use [FileType.custom] with `sf2` on Android: [MimeTypeMap] has no mapping for that extension, so the
  /// plugin gets zero MIME types and returns an error without opening any UI.
  Future<void> _pickSoundfontForWebView(
      InAppWebViewController controller) async {
    debugPrint('pickSoundfont: opening native file picker');
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowCompression: false,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final lower = file.name.toLowerCase();
      if (!lower.endsWith('.sf2')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please choose a SoundFont file (.sf2).')),
        );
        return;
      }
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        debugPrint('pickSoundfont: empty file bytes');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Could not read that file. Try a smaller .sf2 or copy it to local storage.')),
          );
        }
        return;
      }
      try {
        final ok =
            await _nativeUsbSynth.invokeMethod<bool>('loadSoundfont', bytes);
        if (ok != true) {
          debugPrint(
              'pickSoundfont: native USB synth did not accept soundfont');
        }
      } catch (e, st) {
        debugPrint('pickSoundfont: native loadSoundfont failed: $e\n$st');
      }
      final payload =
          jsonEncode({'name': file.name, 'b64': base64Encode(bytes)});
      _runJs(controller, 'window.__dijiOnNativeSoundfont($payload);');
    } catch (e) {
      debugPrint('pickSoundfont error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $e')),
        );
      }
    }
  }

  /// Play tab: load .mid into WebView list (same Storage Access Framework path as [pickSoundfont]).
  Future<String> _midiLibraryManifestForWebView(
      InAppWebViewController controller) async {
    try {
      return await MidiLibraryAssets.readManifestJson();
    } catch (e, st) {
      debugPrint('midiLibraryManifest: $e\n$st');
      return '{"version":1,"rootLabel":"MIDI Library","children":[]}';
    }
  }

  Future<String> _midiLibraryLoadForWebView(
    InAppWebViewController controller,
    List<dynamic> args,
  ) async {
    final key = args.isNotEmpty ? args.first?.toString() : null;
    if (key == null || !MidiLibraryAssets.isAllowedAssetKey(key)) {
      return jsonEncode({'error': 'invalid asset path'});
    }
    try {
      final b64 = await MidiLibraryAssets.loadAssetAsBase64(key);
      return jsonEncode({
        'name': MidiLibraryAssets.basename(key),
        'b64': b64,
      });
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  Future<void> _pickMidiFileForWebView(
      InAppWebViewController controller) async {
    debugPrint('pickMidiFile: opening native file picker');
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowCompression: false,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final lower = file.name.toLowerCase();
      if (!lower.endsWith('.mid') && !lower.endsWith('.midi')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please choose a MIDI file (.mid or .midi).')),
        );
        return;
      }
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        debugPrint('pickMidiFile: empty file bytes');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Could not read that file. Try a smaller file or copy it to local storage.')),
          );
        }
        return;
      }
      final payload =
          jsonEncode({'name': file.name, 'b64': base64Encode(bytes)});
      _runJs(controller, 'window.__dijiOnNativeMidiFile($payload);');
    } catch (e) {
      debugPrint('pickMidiFile error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $e')),
        );
      }
    }
  }

  void _injectLogo() {
    final uri = _logoDataUri;
    final c = _controller;
    if (uri == null || c == null) return;
    final escaped = uri.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    _runJs(
      c,
      "var e=document.getElementById('hero-logo');var s=document.getElementById('hero-logo-svg');"
      "if(e){e.src='$escaped';e.style.display='';e.onerror=null;}if(s)s.style.display='none';",
    );
  }

  /// Re-apply after each load: UserScript early-return can skip flags if AndroidBLE already existed from a prior context.
  void _injectNativeBridgeFlags(InAppWebViewController c) {
    _runJs(c,
        'window.__dijiNativeUsbMidi=true;window.__dijiNativeSoundfontPicker=true;');
  }

  void _notifyNativeUsbSynthInstrument(int bank, int preset,
      {int? sustainPedal}) {
    final args = <String, dynamic>{
      'bank': bank,
      'preset': preset,
    };
    if (sustainPedal != null) {
      args['sustainPedal'] = sustainPedal.clamp(0, 1);
    }
    unawaited(
      _nativeUsbSynth.invokeMethod<void>('applyInstrument', args).catchError(
            (Object e) => debugPrint('native applyInstrument: $e'),
          ),
    );
  }

  void _onNativeUsbSynthInstrumentFromWeb(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return;
      final m = Map<String, dynamic>.from(decoded);
      final bank = (m['bank'] as num?)?.toInt() ?? 0;
      final preset = (m['preset'] as num?)?.toInt() ?? 0;
      int? sustainPedal;
      if (m.containsKey('sustainPedal')) {
        final v = m['sustainPedal'];
        if (v is num) sustainPedal = v.toInt().clamp(0, 1);
      }
      _notifyNativeUsbSynthInstrument(bank, preset, sustainPedal: sustainPedal);
    } catch (e) {
      debugPrint('nativeUsbSynthInstrument: $e');
    }
  }

  /// USB MIDI audio goes through native TinySoundFont, not Web FluidSynth — keep it in sync when the page loads a bundled .sf2 (quick instruments).
  Future<void> _loadBundledSoundfontIntoNativeUsbSynthFromWeb(
      String jsonStr) async {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return;
      final m = Map<String, dynamic>.from(decoded);
      final rel = m['assetRelative'] as String?;
      if (rel == null || rel.trim().isEmpty) return;
      final path = rel.startsWith('assets/') ? rel : 'assets/${rel.trim()}';
      final bd = await rootBundle.load(path);
      final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      final ok =
          await _nativeUsbSynth.invokeMethod<bool>('loadSoundfont', bytes);
      if (ok != true) {
        debugPrint(
            'nativeUsbSynthLoadBundledSf2: native engine did not accept $path');
      }
    } catch (e, st) {
      debugPrint('nativeUsbSynthLoadBundledSf2: $e\n$st');
    }
  }

  Future<void> _startAssetHost() async {
    try {
      await _assetServer.start();
      if (!mounted) return;
      setState(() {
        _webEntryUrl = 'http://127.0.0.1:${_assetServer.port}/qui-skinned.html';
      });
    } catch (e, st) {
      debugPrint('Android asset localhost server failed: $e\n$st');
      if (mounted) {
        setState(() => _error =
            'Could not start local server for WebView assets (port ${_assetServer.port} in use?): $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _bleBridge.onBleDisconnectedByRemote = _notifyBleDisconnectedUi;
    _usbMidiMethod.setMethodCallHandler(_onUsbMidiCallFromPlatform);
    _initLogo();
    unawaited(_startAssetHost());
    Future.delayed(_maxSpinnerDuration, () {
      if (mounted) setState(() => _loading = false);
    });
  }

  (int count, String deviceNames) _parseUsbMidiPortPayload(dynamic raw) {
    if (raw is int) return (raw, '');
    if (raw is Map) {
      final c = raw['count'];
      final n = c is int ? c : (c is num ? c.toInt() : 0);
      final dn = raw['deviceNames'];
      final s = dn is String ? dn : '';
      return (n, s);
    }
    return (0, '');
  }

  void _notifyWebUsbMidiPorts(
      InAppWebViewController c, int count, String deviceNames) {
    final namesJson = jsonEncode(deviceNames);
    _runJs(
      c,
      'try{if(window._usbMidiNativePortCountUpdate)window._usbMidiNativePortCountUpdate($count,$namesJson);}catch(e){}',
    );
  }

  /// Native side pushes real port count after [MidiManager.openDevice] completes (async).
  Future<dynamic> _onUsbMidiCallFromPlatform(MethodCall call) async {
    if (call.method != 'usbMidiPortsUpdated') return null;
    final (n, names) = _parseUsbMidiPortPayload(call.arguments);
    final c = _controller;
    if (c != null && mounted) {
      _notifyWebUsbMidiPorts(c, n, names);
    }
    return null;
  }

  void _scheduleUsbMidiPortPoll(InAppWebViewController controller) {
    for (final delayMs in <int>[600, 1800, 4000]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () async {
        if (!mounted || _controller != controller) return;
        try {
          final raw = await _usbMidiMethod.invokeMethod<dynamic>('portCount');
          final (count, names) = _parseUsbMidiPortPayload(raw);
          _notifyWebUsbMidiPorts(controller, count, names);
        } catch (_) {}
      });
    }
  }

  Future<void> _initLogo() async {
    try {
      final logoData = await rootBundle.load('assets/logo.png');
      final bytes = logoData.buffer
          .asUint8List(logoData.offsetInBytes, logoData.lengthInBytes);
      final b64 = base64Encode(bytes);
      final mime = (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8)
          ? 'image/jpeg'
          : 'image/png';
      if (mounted) setState(() => _logoDataUri = 'data:$mime;base64,$b64');
    } catch (e) {
      debugPrint('Android WebView logo load: $e');
    }
  }

  @override
  void dispose() {
    _bleBridge.onBleDisconnectedByRemote = null;
    _usbMidiMethod.setMethodCallHandler(null);
    _usbMidiSub?.cancel();
    _usbMidiSub = null;
    unawaited(
        _usbMidiMethod.invokeMethod<void>('stop').catchError((Object _) {}));
    unawaited(_assetServer.close().catchError((Object _) {}));
    _bleBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text('Failed to load: $_error', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final entry = _webEntryUrl;
    if (entry == null) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TopLinksStrip(
                    onFirmwareUpdate: () {
                      Navigator.of(context, rootNavigator: true).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const FirmwareUpdateScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Starting…', textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TopLinksStrip(
                  onFirmwareUpdate: () {
                    Navigator.of(context, rootNavigator: true).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const FirmwareUpdateScreen(),
                      ),
                    );
                  },
                ),
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: InAppWebView(
                      key: ValueKey<String>(entry),
                      initialUrlRequest: URLRequest(url: WebUri(entry)),
                      initialUserScripts: UnmodifiableListView<UserScript>([
                        UserScript(
                          source: _bridgeScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                      ]),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        allowFileAccess: true,
                        allowContentAccess: true,
                        // Hybrid composition can leave Web Audio (AudioWorklet) inaudible on some devices; texture mode routes audio reliably.
                        useHybridComposition: false,
                        useShouldOverrideUrlLoading: true,
                        // Default is true on Android and silences Web Audio / AudioWorklet (FluidSynth) output.
                        mediaPlaybackRequiresUserGesture: false,
                      ),
                      shouldOverrideUrlLoading: openExternalHttpInSystemBrowser,
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        _usbMidiSub?.cancel();
                        _usbMidiSub =
                            _usbMidiEvents.receiveBroadcastStream().listen(
                                  _onUsbMidiBytes,
                                  onError: (Object e) =>
                                      debugPrint('USB MIDI stream: $e'),
                                );
                        controller.addJavaScriptHandler(
                          handlerName: 'ble',
                          callback: (args) async {
                            if (args.isNotEmpty && args.first != null) {
                              await _onBleMessage(args.first.toString());
                            }
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'usbMidi',
                          callback: (args) {
                            if (args.isNotEmpty && args.first != null) {
                              _onUsbMidiControlMessage(args.first.toString());
                            }
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'pickSoundfont',
                          callback: (_) {
                            final c = _controller;
                            if (c == null) return;
                            unawaited(_pickSoundfontForWebView(c));
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'pickMidiFile',
                          callback: (_) {
                            final c = _controller;
                            if (c == null) return;
                            unawaited(_pickMidiFileForWebView(c));
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'probeOtaInstrument',
                          callback: (_) async {
                            try {
                              return await WifiFirmwareOta.probeDevice(
                                WifiFirmwareOta.normalizeDeviceBase(''),
                              );
                            } catch (e) {
                              debugPrint('probeOtaInstrument: $e');
                              return false;
                            }
                          },
                        );
                        registerOtaFirmwareJavaScriptHandlers(controller);
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'openFirmwareUpdateScreen',
                            callback: (_) async {
                              if (!mounted) return;
                              await Navigator.of(context, rootNavigator: true).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => const FirmwareUpdateScreen(),
                                ),
                              );
                            },
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'openFirmwareUpdateScreenWithFirmware',
                            callback: (args) async {
                              if (!mounted) return;
                              final name = args.isNotEmpty
                                  ? (args[0]?.toString() ?? 'firmware.bin')
                                  : 'firmware.bin';
                              if (args.length < 2 || args[1] == null) {
                                await Navigator.of(context, rootNavigator: true).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const FirmwareUpdateScreen(),
                                  ),
                                );
                                return;
                              }
                              try {
                                final bytes = Uint8List.fromList(
                                  base64Decode(args[1].toString()),
                                );
                                if (!mounted) return;
                                await Navigator.of(context, rootNavigator: true).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) => FirmwareUpdateScreen(
                                      initialFirmwareBytes: bytes,
                                      initialFirmwareName: name,
                                    ),
                                  ),
                                );
                              } catch (e) {
                                debugPrint(
                                    'openFirmwareUpdateScreenWithFirmware: $e');
                                if (!mounted) return;
                                await Navigator.of(context, rootNavigator: true).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const FirmwareUpdateScreen(),
                                  ),
                                );
                              }
                            },
                          );
                        } catch (_) {}
                        controller.addJavaScriptHandler(
                          handlerName: 'openExternalUrl',
                          callback: (args) async {
                            if (args.isEmpty || args.first == null) return;
                            final uri = Uri.tryParse(args.first.toString());
                            if (uri == null) return;
                            try {
                              await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                            } catch (e) {
                              debugPrint('openExternalUrl: $e');
                            }
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'midiLibraryManifest',
                          callback: (_) {
                            final c = _controller;
                            if (c == null) return '';
                            return _midiLibraryManifestForWebView(c);
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'midiLibraryLoad',
                          callback: (args) {
                            final c = _controller;
                            if (c == null)
                              return jsonEncode({'error': 'no controller'});
                            return _midiLibraryLoadForWebView(c, args);
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'nativeUsbSynthInstrument',
                          callback: (args) {
                            if (args.isEmpty || args.first == null) return;
                            _onNativeUsbSynthInstrumentFromWeb(
                                args.first.toString());
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'nativeUsbSynthLoadBundledSf2',
                          callback: (args) async {
                            if (args.isEmpty || args.first == null) return;
                            await _loadBundledSoundfontIntoNativeUsbSynthFromWeb(
                              args.first.toString(),
                            );
                          },
                        );
                      },
                      onLoadStop: (controller, url) {
                        _injectNativeBridgeFlags(controller);
                        _injectLogo();
                        Future.delayed(const Duration(milliseconds: 100), () {
                          _injectNativeBridgeFlags(controller);
                          _injectLogo();
                        });
                        if (mounted) setState(() => _loading = false);
                      },
                      onReceivedError: (controller, request, error) {
                        debugPrint('WebView error: ${error.description}');
                        if (mounted) setState(() => _loading = false);
                      },
                    ),
                  ),
                  if (_loading)
                    const Center(child: CircularProgressIndicator()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
