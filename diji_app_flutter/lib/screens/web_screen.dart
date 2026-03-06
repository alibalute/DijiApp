import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:diji_app_flutter/ble/ble_bridge.dart';

class WebScreen extends StatefulWidget {
  const WebScreen({super.key});

  @override
  State<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends State<WebScreen> {
  InAppWebViewController? _webViewController;
  final BleBridge _bleBridge = BleBridge();
  bool _loading = true;
  /// Never show spinner longer than this; onLoadStop is unreliable on Android.
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
    final controller = _webViewController;
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
            _runJs(controller, "if (window._bleOnNotification) window._bleOnNotification($escaped);");
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

  void _stopLoading() {
    if (_loading && mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    // On Android, onLoadStop often never fires for local content. Always hide spinner after max duration.
    Future.delayed(_maxSpinnerDuration, () {
      if (mounted) _stopLoading();
    });
  }

  @override
  void dispose() {
    _bleBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: InAppWebView(
              // Used for web and iOS (Android uses AndroidWebViewScreen).
              initialFile: kIsWeb ? null : 'assets/qui-skinned.html',
              initialUrlRequest: kIsWeb
                  ? URLRequest(
                      url: WebUri(Uri.base.resolve('assets/qui-skinned.html').toString()),
                    )
                  : null,
              initialSettings: InAppWebViewSettings(
                transparentBackground: false,
                javaScriptEnabled: true,
                allowFileAccess: true,
                allowContentAccess: true,
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _bridgeScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                if (!kIsWeb) {
                  try {
                    controller.addJavaScriptHandler(
                      handlerName: 'ble',
                      callback: (args) {
                        if (args.isNotEmpty && args.first != null) {
                          _onBleMessage(args.first.toString());
                        }
                      },
                    );
                  } catch (_) {}
                }
              },
              onLoadStop: (controller, url) {
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
    );
  }
}
