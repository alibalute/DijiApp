import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show EventChannel, MethodCall, MethodChannel, PlatformException, rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:diji_app_flutter/ble/ble_bridge.dart';
import 'package:diji_app_flutter/midi_library_assets.dart';
import 'package:diji_app_flutter/screens/firmware_update_screen.dart';
import 'package:diji_app_flutter/services/wifi_firmware_ota.dart';
import 'package:diji_app_flutter/webview_external_navigation.dart';
import 'package:diji_app_flutter/webview_ota_handlers.dart';
import 'package:diji_app_flutter/widgets/top_links_strip.dart';

class WebScreen extends StatefulWidget {
  const WebScreen({super.key});

  @override
  State<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends State<WebScreen> {
  InAppWebViewController? _webViewController;
  final BleBridge _bleBridge = BleBridge();
  bool _loading = true;

  /// Same as [AndroidWebViewScreen]: AudioWorklet / WASM are unreliable from `file://` on some OS builds.
  InAppLocalhostServer? _iosAssetServer;

  /// Set after [_iosAssetServer] starts; iOS WebView loads [qui-skinned.html] from this origin.
  String? _iosWebEntryUrl;
  String? _iosAssetError;

  /// Never show spinner longer than this; onLoadStop is unreliable on Android.
  static const Duration _maxSpinnerDuration = Duration(milliseconds: 2500);

  static const int _iosAssetPort = 8788;

  bool get _useIosLocalhostAssets =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Same channel names as [AndroidWebViewScreen] / [UsbMidiBridge.kt] and [IosUsbMidiBridge.swift].
  static const MethodChannel _usbMidiMethod =
      MethodChannel('com.example.diji_app_flutter/usb_midi');
  static const EventChannel _usbMidiEvents =
      EventChannel('com.example.diji_app_flutter/usb_midi_stream');
  StreamSubscription<dynamic>? _iosUsbMidiSub;

  static const String _bridgeScript = r'''
(function() {
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
    final controller = _webViewController;
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
            _runJs(
              controller,
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

  void _runJs(InAppWebViewController c, String js) {
    c.evaluateJavascript(source: js);
  }

  void _notifyBleDisconnectedUi() {
    final c = _webViewController;
    if (c == null || !mounted) return;
    c.evaluateJavascript(
      source:
          "try{if(window.__dijiOnBleDisconnected)window.__dijiOnBleDisconnected();}catch(e){}",
    );
  }

  void _onIosUsbMidiBytes(dynamic data) {
    final controller = _webViewController;
    if (controller == null) return;
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
      return;
    }
    if (bytes.isEmpty) return;
    final b64 = base64Encode(bytes);
    final safe = b64.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    _runJs(
      controller,
      "try{if(window._nativeUsbMidiMessage)window._nativeUsbMidiMessage('$safe');}catch(e){}",
    );
  }

  Future<void> _onIosUsbMidiControlMessage(String jsonStr) async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final action = map['action'] as String?;
      if (action == 'start') {
        try {
          final dynamic n = await _usbMidiMethod.invokeMethod<dynamic>('start');
          final count = n is int ? n : (n is num ? n.toInt() : 0);
          _runJs(controller, 'window._usbMidiNativeStarted(true, $count);');
          _scheduleIosUsbMidiPortPoll(controller);
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
      debugPrint('USB MIDI handler (iOS): $e');
    }
  }

  (int count, String deviceNames) _parseIosUsbMidiPortPayload(dynamic raw) {
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

  void _notifyIosWebUsbMidiPorts(
    InAppWebViewController c,
    int count,
    String deviceNames,
  ) {
    final namesJson = jsonEncode(deviceNames);
    _runJs(
      c,
      'try{if(window._usbMidiNativePortCountUpdate)window._usbMidiNativePortCountUpdate($count,$namesJson);}catch(e){}',
    );
  }

  Future<dynamic> _onIosUsbMidiCallFromPlatform(MethodCall call) async {
    if (call.method != 'usbMidiPortsUpdated') return null;
    final (n, names) = _parseIosUsbMidiPortPayload(call.arguments);
    final c = _webViewController;
    if (c != null && mounted) {
      _notifyIosWebUsbMidiPorts(c, n, names);
    }
    return null;
  }

  void _scheduleIosUsbMidiPortPoll(InAppWebViewController controller) {
    for (final delayMs in <int>[600, 1800, 4000]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () async {
        if (!mounted || _webViewController != controller) return;
        try {
          final raw = await _usbMidiMethod.invokeMethod<dynamic>('portCount');
          final (count, names) = _parseIosUsbMidiPortPayload(raw);
          _notifyIosWebUsbMidiPorts(controller, count, names);
        } catch (_) {}
      });
    }
  }

  /// Web / iOS / desktop embedders: `<input type="file">` often hides `.sf2`; use [FileType.any] + filter.
  /// (Android app uses [AndroidWebViewScreen] with native picker + TinySoundFont.)
  Future<void> _pickSoundfontForWebView(
      InAppWebViewController controller) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowCompression: false,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (!file.name.toLowerCase().endsWith('.sf2')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please choose a SoundFont file (.sf2).')),
        );
        return;
      }
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        debugPrint('pickSoundfont: empty file bytes');
        return;
      }
      final payload =
          jsonEncode({'name': file.name, 'b64': base64Encode(bytes)});
      _runJs(controller, 'window.__dijiOnNativeSoundfont($payload);');
    } catch (e) {
      debugPrint('pickSoundfont error: $e');
    }
  }

  Future<Map<String, dynamic>> _loadBundledSf2BytesForWebView(
    List<dynamic> args,
  ) async {
    final rel = args.isNotEmpty ? args.first?.toString() : null;
    if (rel == null || rel.trim().isEmpty) {
      return {'error': 'missing asset path'};
    }
    final normalized = rel.trim().replaceAll(r'\', '/');
    final key = normalized.startsWith('assets/')
        ? normalized
        : 'assets/$normalized';
    try {
      final bd = await rootBundle.load(key);
      final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      return {
        'path': normalized,
        'name': normalized.split('/').isNotEmpty
            ? normalized.split('/').last
            : 'soundfont.sf2',
        'b64': base64Encode(bytes),
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Play tab: load .mid into WebView list (same [FilePicker] path as soundfont on iOS/desktop embedder).
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
        return;
      }
      final payload =
          jsonEncode({'name': file.name, 'b64': base64Encode(bytes)});
      _runJs(controller, 'window.__dijiOnNativeMidiFile($payload);');
    } catch (e) {
      debugPrint('pickMidiFile error: $e');
    }
  }

  UnmodifiableListView<UserScript> _initialUserScripts() {
    final list = <UserScript>[];
    if (kIsWeb) {
      list.add(
        UserScript(
          source: 'window.__dijiFlutterWeb=true;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    }
    // Flutter web (Chrome): keep the browser's real Web Bluetooth. qui-skinned only
    // replaces navigator.bluetooth when AndroidBLE exists (Android / iOS / desktop embedder).
    if (!kIsWeb) {
      list.add(
        UserScript(
          source: _bridgeScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    }
    if (_useIosLocalhostAssets) {
      list.add(
        UserScript(
          source: 'window.__dijiNativeUsbMidi=true;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    }
    list.add(
      UserScript(
        source: 'window.__dijiNativeSoundfontPicker=true;',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    );
    return UnmodifiableListView<UserScript>(list);
  }

  Future<void> _startIosAssetHost() async {
    final server = _iosAssetServer;
    if (server == null) return;
    try {
      await server.start();
      if (!mounted) return;
      setState(() {
        _iosWebEntryUrl = 'http://127.0.0.1:${server.port}/qui-skinned.html';
      });
    } catch (e, st) {
      debugPrint('iOS asset localhost server failed: $e\n$st');
      if (mounted) {
        setState(() {
          _iosAssetError =
              'Could not start local server for WebView assets (port ${server.port} in use?): $e';
        });
      }
    }
  }

  void _stopLoading() {
    if (_loading && mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _bleBridge.onBleDisconnectedByRemote = _notifyBleDisconnectedUi;
    if (_useIosLocalhostAssets) {
      _iosAssetServer =
          InAppLocalhostServer(port: _iosAssetPort, documentRoot: 'assets');
      unawaited(_startIosAssetHost());
      _usbMidiMethod.setMethodCallHandler(_onIosUsbMidiCallFromPlatform);
    }
    // On Android, onLoadStop often never fires for local content. Always hide spinner after max duration.
    Future.delayed(_maxSpinnerDuration, () {
      if (mounted) _stopLoading();
    });
  }

  @override
  void dispose() {
    _bleBridge.onBleDisconnectedByRemote = null;
    if (_useIosLocalhostAssets) {
      _usbMidiMethod.setMethodCallHandler(null);
      _iosUsbMidiSub?.cancel();
      _iosUsbMidiSub = null;
      unawaited(
          _usbMidiMethod.invokeMethod<void>('stop').catchError((Object _) {}));
    }
    unawaited(_iosAssetServer?.close().catchError((Object _) {}));
    _iosAssetServer = null;
    _bleBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_useIosLocalhostAssets) {
      final err = _iosAssetError;
      if (err != null) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(err, textAlign: TextAlign.center)),
            ),
          ),
        );
      }
      if (_iosWebEntryUrl == null) {
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
    }

    final iosEntry = _iosWebEntryUrl;

    // iOS WKWebView is a platform view that often draws above Flutter widgets in a Stack.
    // Keep TopLinksStrip in a Column above the WebView so it is never occluded.
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
                      key: iosEntry != null ? ValueKey<String>(iosEntry) : null,
                      // Used for web and iOS (Android uses AndroidWebViewScreen).
                      initialFile: (kIsWeb || iosEntry != null)
                          ? null
                          : 'assets/qui-skinned.html',
                      initialUrlRequest: kIsWeb
                          ? URLRequest(
                              url: WebUri(
                                Uri.base
                                    // Flutter web serves bundled assets under /assets/assets/<file>.
                                    .resolve('assets/assets/qui-skinned.html')
                                    .toString(),
                              ),
                            )
                          : (iosEntry != null
                              ? URLRequest(url: WebUri(iosEntry))
                              : null),
                      initialSettings: InAppWebViewSettings(
                        transparentBackground: false,
                        javaScriptEnabled: true,
                        allowFileAccess: true,
                        allowContentAccess: true,
                        useShouldOverrideUrlLoading: !kIsWeb,
                        // Match Android WebView: default true silences Web Audio / AudioWorklet (FluidSynth).
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                      ),
                      shouldOverrideUrlLoading:
                          kIsWeb ? null : openExternalHttpInSystemBrowser,
                      initialUserScripts: _initialUserScripts(),
                      onWebViewCreated: (controller) {
                        _webViewController = controller;
                        if (!kIsWeb) {
                          try {
                            controller.addJavaScriptHandler(
                              handlerName: 'ble',
                              callback: (args) async {
                                if (args.isNotEmpty && args.first != null) {
                                  await _onBleMessage(args.first.toString());
                                }
                              },
                            );
                          } catch (_) {}
                        }
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'pickSoundfont',
                            callback: (_) =>
                                _pickSoundfontForWebView(controller),
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'loadBundledSf2Bytes',
                            callback: _loadBundledSf2BytesForWebView,
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'pickMidiFile',
                            callback: (_) =>
                                _pickMidiFileForWebView(controller),
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'openExternalUrl',
                            callback: (args) async {
                              if (args.isEmpty || args.first == null) return;
                              final uri = Uri.tryParse(args.first.toString());
                              if (uri == null) return;
                              try {
                                if (kIsWeb) {
                                  await launchUrl(
                                    uri,
                                    webOnlyWindowName: '_blank',
                                  );
                                } else {
                                  await launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              } catch (e) {
                                debugPrint('openExternalUrl: $e');
                              }
                            },
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'probeOtaInstrument',
                            callback: (_) async {
                              if (kIsWeb) return false;
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
                        } catch (_) {}
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
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'midiLibraryManifest',
                            callback: (_) =>
                                _midiLibraryManifestForWebView(controller),
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'midiLibraryLoad',
                            callback: (args) =>
                                _midiLibraryLoadForWebView(controller, args),
                          );
                        } catch (_) {}
                        // Android-only native USB synth; JS always calls these when the bridge exists.
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'nativeUsbSynthInstrument',
                            callback: (_) async {},
                          );
                        } catch (_) {}
                        try {
                          controller.addJavaScriptHandler(
                            handlerName: 'nativeUsbSynthLoadBundledSf2',
                            callback: (_) async => false,
                          );
                        } catch (_) {}
                        if (_useIosLocalhostAssets) {
                          _iosUsbMidiSub?.cancel();
                          _iosUsbMidiSub =
                              _usbMidiEvents.receiveBroadcastStream().listen(
                                    _onIosUsbMidiBytes,
                                    onError: (Object e) =>
                                        debugPrint('USB MIDI stream (iOS): $e'),
                                  );
                          try {
                            controller.addJavaScriptHandler(
                              handlerName: 'usbMidi',
                              callback: (args) {
                                if (args.isNotEmpty && args.first != null) {
                                  unawaited(
                                    _onIosUsbMidiControlMessage(
                                      args.first.toString(),
                                    ),
                                  );
                                }
                              },
                            );
                          } catch (_) {}
                        }
                      },
                      onLoadStop: (controller, url) {
                        if (_useIosLocalhostAssets) {
                          _runJs(
                            controller,
                            'window.__dijiNativeSoundfontPicker=true;window.__dijiNativeUsbMidi=true;',
                          );
                        }
                        _stopLoading();
                      },
                      onReceivedError: (controller, request, error) {
                        _stopLoading();
                        debugPrint('WebView load error: ${error.description}');
                      },
                    ),
                  ),
                  if (_loading)
                    const Center(
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
