import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:diji_app_flutter/ble/ble_bridge.dart';

/// Android-only WebView. Loads HTML via data URI (reliable); logo embedded as data URI in HTML.
class AndroidWebViewScreen extends StatefulWidget {
  const AndroidWebViewScreen({super.key});

  @override
  State<AndroidWebViewScreen> createState() => _AndroidWebViewScreenState();
}

class _AndroidWebViewScreenState extends State<AndroidWebViewScreen> {
  final BleBridge _bleBridge = BleBridge();
  WebViewController? _controller;
  bool _loading = true;
  String? _error;
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
              await controller.runJavaScript("window._bleResolve($callbackId, '$escaped');");
            } else {
              await controller.runJavaScript("window._bleReject($callbackId, 'No device selected');");
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
                await controller.runJavaScript("window._bleOnConnect($callbackId);");
              } else {
                await controller.runJavaScript("window._bleReject($callbackId, 'Service or characteristic not found');");
              }
            } catch (e) {
              final msg = e.toString().replaceAll(r'\', r'\\').replaceAll("'", r"\'");
              await controller.runJavaScript("window._bleReject($callbackId, '$msg');");
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
            controller.runJavaScript("if (window._bleOnNotification) window._bleOnNotification($escaped);");
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

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _injectLogo() {
    final uri = _logoDataUri;
    final c = _controller;
    if (uri == null || c == null) return;
    final escaped = uri.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    c.runJavaScript(
      "var e=document.getElementById('hero-logo');var s=document.getElementById('hero-logo-svg');"
      "if(e){e.src='$escaped';e.style.display='';e.onerror=null;}if(s)s.style.display='none';",
    );
  }

  Future<void> _initWebView() async {
    try {
      String html = await rootBundle.loadString('assets/qui-skinned.html');

      // Load logo for injection after page load (data-URI doc doesn't resolve relative logo.png).
      try {
        final logoData = await rootBundle.load('assets/logo.png');
        final bytes = logoData.buffer.asUint8List(logoData.offsetInBytes, logoData.lengthInBytes);
        final b64 = base64Encode(bytes);
        final mime = (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) ? 'image/jpeg' : 'image/png';
        _logoDataUri = 'data:$mime;base64,$b64';
      } catch (_) {}

      // BLE bridge at start of <head> so navigator.bluetooth is set before page script runs.
      const shim = r'''window.flutter_inappwebview={callHandler:function(n,d){if(n==='ble'&&window.ble&&window.ble.postMessage)window.ble.postMessage(d);}};''';
      final injected = html.replaceFirst('<head>', '<head><script>$shim$_bridgeScript</script>');

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('ble', onMessageReceived: (message) {
            _onBleMessage(message.message);
          })
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              _injectLogo();
              Future.delayed(const Duration(milliseconds: 100), () => _injectLogo());
              if (mounted) setState(() => _loading = false);
            },
            onWebResourceError: (e) {
              debugPrint('WebView error: ${e.description}');
              if (mounted) setState(() => _loading = false);
            },
          ),
        );

      _controller = controller;

      await controller.loadRequest(
        Uri.dataFromString(injected, mimeType: 'text/html', encoding: utf8),
      );

      if (mounted) setState(() {});
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
    if (_controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            WebViewWidget(controller: _controller!),
            if (_loading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
