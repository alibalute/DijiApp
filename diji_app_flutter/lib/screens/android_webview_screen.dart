import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:diji_app_flutter/ble/ble_bridge.dart';

/// Android-only WebView. Loads HTML via data (reliable); logo embedded as data URI in HTML.
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
  String? _injectedHtml;
  String? _logoDataUri;

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
          _bleBridge.startNotifications((base64) {
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
    _initHtml();
  }

  Future<void> _initHtml() async {
    try {
      final html = await rootBundle.loadString('assets/qui-skinned.html');
      try {
        final logoData = await rootBundle.load('assets/logo.png');
        final bytes = logoData.buffer.asUint8List(logoData.offsetInBytes, logoData.lengthInBytes);
        final b64 = base64Encode(bytes);
        final mime = (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) ? 'image/jpeg' : 'image/png';
        _logoDataUri = 'data:$mime;base64,$b64';
      } catch (_) {}
      final injected = html.replaceFirst('<head>', '<head><script>$_bridgeScript</script>');
      if (mounted) setState(() => _injectedHtml = injected);
    } catch (e) {
      debugPrint('Android WebView init error: $e');
      if (mounted) setState(() => _error = e.toString());
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
    if (_injectedHtml == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: InAppWebView(
                initialData: InAppWebViewInitialData(
                  data: _injectedHtml!,
                  mimeType: 'text/html',
                  encoding: 'utf-8',
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  allowFileAccess: true,
                ),
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
            if (_loading)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
