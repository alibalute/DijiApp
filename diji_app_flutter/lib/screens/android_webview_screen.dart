import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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
  final BleBridge _bleBridge = BleBridge();
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _error;
  String? _logoDataUri;

  /// Horizontal accumulation for edge swipe zones (center WebView stays free for sliders).
  double _edgeDragDx = 0;

  /// Same workaround as [WebScreen]: on Android, [onLoadStop] can be late; never block UI forever.
  static const Duration _maxSpinnerDuration = Duration(milliseconds: 2500);

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
            final escaped = jsonEncode(base64);
            controller.evaluateJavascript(source: "if (window._bleOnNotification) window._bleOnNotification($escaped);");
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

  void _runJs(InAppWebViewController c, String js) {
    c.evaluateJavascript(source: js);
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

  @override
  void initState() {
    super.initState();
    _initLogo();
    Future.delayed(_maxSpinnerDuration, () {
      if (mounted) setState(() => _loading = false);
    });
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
                      initialFile: 'assets/qui-skinned.html',
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
                        useHybridComposition: true,
                        useShouldOverrideUrlLoading: true,
                      ),
                      shouldOverrideUrlLoading: openExternalHttpInSystemBrowser,
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        controller.addJavaScriptHandler(
                          handlerName: 'ble',
                          callback: (args) {
                            if (args.isNotEmpty && args.first != null) {
                              _onBleMessage(args.first.toString());
                            }
                          },
                        );
                      },
                      onLoadStop: (controller, url) {
                        _injectLogo();
                        Future.delayed(const Duration(milliseconds: 100), () => _injectLogo());
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
