import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show EventChannel, MethodCall, MethodChannel, PlatformException, rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:diji_app_flutter/ble/ble_bridge.dart';
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
  final InAppLocalhostServer _assetServer = InAppLocalhostServer(port: 8787, documentRoot: 'assets');
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _error;
  String? _logoDataUri;
  /// Set after [_assetServer] starts; WebView loads [qui-skinned.html] from this origin.
  String? _webEntryUrl;

  /// Horizontal accumulation for edge swipe zones (center WebView stays free for sliders).
  double _edgeDragDx = 0;

  /// Same workaround as [WebScreen]: on Android, [onLoadStop] can be late; never block UI forever.
  static const Duration _maxSpinnerDuration = Duration(milliseconds: 2500);

  static const MethodChannel _usbMidiMethod = MethodChannel('com.example.diji_app_flutter/usb_midi');
  static const EventChannel _usbMidiEvents = EventChannel('com.example.diji_app_flutter/usb_midi_stream');

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

  void _onBleMessage(String jsonStr) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final method = map['method'] as String?;
      switch (method) {
        case 'requestDevice':
          final rawId = map['callbackId'];
          final callbackId = rawId is int ? rawId : (rawId is num ? rawId.toInt() : null);
          if (callbackId != null) {
            final result = await _bleBridge.requestDevice();
            if (result != null) {
              final deviceJson = jsonEncode({'id': result.id, 'name': result.name});
              final escaped = deviceJson.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
              _runJs(controller, "window._bleResolve($callbackId, '$escaped');");
            } else {
              _runJs(controller, "window._bleReject($callbackId, 'No device selected');");
            }
          }
          break;
        case 'connect':
          final deviceId = map['deviceId'] as String?;
          final rawCid = map['callbackId'];
          final callbackId = rawCid is int ? rawCid : (rawCid is num ? rawCid.toInt() : null);
          if (deviceId != null && callbackId != null) {
            try {
              final ok = await _bleBridge.connect(deviceId);
              if (ok) {
                _runJs(controller, "window._bleOnConnect($callbackId);");
              } else {
                _runJs(controller, "window._bleReject($callbackId, 'Service or characteristic not found');");
              }
            } catch (e) {
              final msg = e.toString().replaceAll(r'\', r'\\').replaceAll("'", r"\'");
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
    } catch (e) {
      debugPrint('BLE bridge error: $e');
    }
  }

  void _onUsbMidiBytes(dynamic data) {
    final controller = _controller;
    if (controller == null) {
      debugPrint('USB MIDI: dropped packet (WebView controller null), type=${data.runtimeType}');
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
      debugPrint('USB MIDI: unexpected EventChannel payload type=${data.runtimeType} value=$data');
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
          final msg = (e.message ?? e.code).replaceAll(r'\', r'\\').replaceAll("'", r"\'");
          _runJs(controller, "window._usbMidiNativeStarted(false, '$msg');");
        } catch (e) {
          final msg = e.toString().replaceAll(r'\', r'\\').replaceAll("'", r"\'");
          _runJs(controller, "window._usbMidiNativeStarted(false, '$msg');");
        }
      } else if (action == 'stop') {
        try {
          await _usbMidiMethod.invokeMethod<void>('stop');
        } catch (_) {}
        _runJs(controller, 'try{if(window._usbMidiNativeStopped)window._usbMidiNativeStopped();}catch(e){}');
      }
    } catch (e) {
      debugPrint('USB MIDI handler: $e');
    }
  }

  void _runJs(InAppWebViewController c, String js) {
    c.evaluateJavascript(source: js);
  }

  /// WebView `<input type="file">` on Android often opens the photo gallery; use Storage Access Framework via file_picker.
  ///
  /// Do not use [FileType.custom] with `sf2` on Android: [MimeTypeMap] has no mapping for that extension, so the
  /// plugin gets zero MIME types and returns an error without opening any UI.
  Future<void> _pickSoundfontForWebView(InAppWebViewController controller) async {
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
          const SnackBar(content: Text('Please choose a SoundFont file (.sf2).')),
        );
        return;
      }
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        debugPrint('pickSoundfont: empty file bytes');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read that file. Try a smaller .sf2 or copy it to local storage.')),
          );
        }
        return;
      }
      try {
        final ok = await _nativeUsbSynth.invokeMethod<bool>('loadSoundfont', bytes);
        if (ok != true) {
          debugPrint('pickSoundfont: native USB synth did not accept soundfont');
        }
      } catch (e, st) {
        debugPrint('pickSoundfont: native loadSoundfont failed: $e\n$st');
      }
      final payload = jsonEncode({'name': file.name, 'b64': base64Encode(bytes)});
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

  /// [delta] +1 = next tab, -1 = previous (wraps).
  void _nudgeTab(int delta) {
    final c = _controller;
    if (c == null) return;
    c.evaluateJavascript(source: '''
(function(){
  var n=document.querySelectorAll('.tab').length;
  if(n<2||typeof openTab!=='function')return;
  var i=typeof currentTabIndex!=='undefined'?currentTabIndex:0;
  openTab((i+$delta+n)%n);
})()
''');
  }

  void _onEdgeHorizontalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    const vTh = 280.0;
    const dTh = 72.0;
    if (v.abs() >= vTh) {
      if (v < 0) {
        _nudgeTab(1);
      } else {
        _nudgeTab(-1);
      }
    } else if (_edgeDragDx.abs() >= dTh) {
      if (_edgeDragDx < 0) {
        _nudgeTab(1);
      } else {
        _nudgeTab(-1);
      }
    }
    _edgeDragDx = 0;
  }

  void _injectLogo() {
    final uri = _logoDataUri;
    final c = _controller;
    if (uri == null || c == null) return;
    final escaped = uri.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    _runJs(c,
      "var e=document.getElementById('hero-logo');var s=document.getElementById('hero-logo-svg');"
      "if(e){e.src='$escaped';e.style.display='';e.onerror=null;}if(s)s.style.display='none';",
    );
  }

  /// Re-apply after each load: UserScript early-return can skip flags if AndroidBLE already existed from a prior context.
  void _injectNativeBridgeFlags(InAppWebViewController c) {
    _runJs(c, 'window.__dijiNativeUsbMidi=true;window.__dijiNativeSoundfontPicker=true;');
  }

  void _notifyNativeUsbSynthInstrument(int bank, int preset) {
    unawaited(
      _nativeUsbSynth.invokeMethod<void>('applyInstrument', <String, int>{
        'bank': bank,
        'preset': preset,
      }).catchError((Object e) => debugPrint('native applyInstrument: $e')),
    );
  }

  void _onNativeUsbSynthInstrumentFromWeb(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return;
      final m = Map<String, dynamic>.from(decoded);
      final bank = (m['bank'] as num?)?.toInt() ?? 0;
      final preset = (m['preset'] as num?)?.toInt() ?? 0;
      _notifyNativeUsbSynthInstrument(bank, preset);
    } catch (e) {
      debugPrint('nativeUsbSynthInstrument: $e');
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
        setState(() => _error = 'Could not start local server for WebView assets (port ${_assetServer.port} in use?): $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _usbMidiMethod.setMethodCallHandler(_onUsbMidiCallFromPlatform);
    _initLogo();
    unawaited(_startAssetHost());
    Future.delayed(_maxSpinnerDuration, () {
      if (mounted) setState(() => _loading = false);
    });
  }

  /// Native side pushes real port count after [MidiManager.openDevice] completes (async).
  Future<dynamic> _onUsbMidiCallFromPlatform(MethodCall call) async {
    if (call.method != 'usbMidiPortsUpdated') return null;
    final raw = call.arguments;
    final n = raw is int ? raw : (raw is num ? raw.toInt() : 0);
    final c = _controller;
    if (c != null && mounted) {
      _runJs(
        c,
        'try{if(window._usbMidiNativePortCountUpdate)window._usbMidiNativePortCountUpdate($n);}catch(e){}',
      );
    }
    return null;
  }

  void _scheduleUsbMidiPortPoll(InAppWebViewController controller) {
    for (final delayMs in <int>[600, 1800, 4000]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () async {
        if (!mounted || _controller != controller) return;
        try {
          final n = await _usbMidiMethod.invokeMethod<dynamic>('portCount');
          final count = n is int ? n : (n is num ? n.toInt() : 0);
          _runJs(
            controller,
            'try{if(window._usbMidiNativePortCountUpdate)window._usbMidiNativePortCountUpdate($count);}catch(e){}',
          );
        } catch (_) {}
      });
    }
  }

  Future<void> _initLogo() async {
    try {
      final logoData = await rootBundle.load('assets/logo.png');
      final bytes = logoData.buffer.asUint8List(logoData.offsetInBytes, logoData.lengthInBytes);
      final b64 = base64Encode(bytes);
      final mime = (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) ? 'image/jpeg' : 'image/png';
      if (mounted) setState(() => _logoDataUri = 'data:$mime;base64,$b64');
    } catch (e) {
      debugPrint('Android WebView logo load: $e');
    }
  }

  @override
  void dispose() {
    _usbMidiMethod.setMethodCallHandler(null);
    _usbMidiSub?.cancel();
    _usbMidiSub = null;
    unawaited(_usbMidiMethod.invokeMethod<void>('stop').catchError((Object _) {}));
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
                  child: TopLinksStrip(),
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
                child: TopLinksStrip(),
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
                          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
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
                        _usbMidiSub = _usbMidiEvents.receiveBroadcastStream().listen(
                          _onUsbMidiBytes,
                          onError: (Object e) => debugPrint('USB MIDI stream: $e'),
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'ble',
                          callback: (args) {
                            if (args.isNotEmpty && args.first != null) {
                              _onBleMessage(args.first.toString());
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
                          handlerName: 'nativeUsbSynthInstrument',
                          callback: (args) {
                            if (args.isEmpty || args.first == null) return;
                            _onNativeUsbSynthInstrumentFromWeb(args.first.toString());
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
                  // Narrow strips only: avoids stealing horizontal drags from <input type="range"> in the WebView.
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 40,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _edgeDragDx = 0,
                      onHorizontalDragUpdate: (d) => _edgeDragDx += d.delta.dx,
                      onHorizontalDragEnd: _onEdgeHorizontalDragEnd,
                      child: const ColoredBox(color: Color(0x00000000)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 40,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _edgeDragDx = 0,
                      onHorizontalDragUpdate: (d) => _edgeDragDx += d.delta.dx,
                      onHorizontalDragEnd: _onEdgeHorizontalDragEnd,
                      child: const ColoredBox(color: Color(0x00000000)),
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
