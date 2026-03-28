import 'dart:collection';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:diji_app_flutter/ble/ble_bridge.dart';
import 'package:diji_app_flutter/webview_external_navigation.dart';
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
    } catch (e) {
      debugPrint('BLE bridge error: $e');
    }
  }

  void _runJs(InAppWebViewController c, String js) {
    c.evaluateJavascript(source: js);
  }

  /// iOS WKWebView document picker often excludes `.sf2` for `<input type="file">`; use UIDocumentPicker via file_picker.
  ///
  /// On Android, [FileType.custom] with `sf2` fails silently (no MIME in [MimeTypeMap]); use [FileType.any] and filter.
  Future<void> _pickSoundfontForWebView(InAppWebViewController controller) async {
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
          const SnackBar(content: Text('Please choose a SoundFont file (.sf2).')),
        );
        return;
      }
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        debugPrint('pickSoundfont: empty file bytes');
        return;
      }
      final payload = jsonEncode({'name': file.name, 'b64': base64Encode(bytes)});
      _runJs(controller, 'window.__dijiOnNativeSoundfont($payload);');
    } catch (e) {
      debugPrint('pickSoundfont error: $e');
    }
  }

  UnmodifiableListView<UserScript> _initialUserScripts() {
    final list = <UserScript>[
      UserScript(
        source: _bridgeScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      list.add(
        UserScript(
          source: 'window.__dijiNativeSoundfontPicker=true;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    }
    return UnmodifiableListView<UserScript>(list);
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
                child: TopLinksStrip(),
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: InAppWebView(
                      // Used for web and iOS (Android uses AndroidWebViewScreen).
                      initialFile: kIsWeb ? null : 'assets/qui-skinned.html',
                      initialUrlRequest: kIsWeb
                          ? URLRequest(
                              url: WebUri(
                                Uri.base.resolve('assets/qui-skinned.html').toString(),
                              ),
                            )
                          : null,
                      initialSettings: InAppWebViewSettings(
                        transparentBackground: false,
                        javaScriptEnabled: true,
                        allowFileAccess: true,
                        allowContentAccess: true,
                        useShouldOverrideUrlLoading: !kIsWeb,
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
                              callback: (args) {
                                if (args.isNotEmpty && args.first != null) {
                                  _onBleMessage(args.first.toString());
                                }
                              },
                            );
                          } catch (_) {}
                          if (defaultTargetPlatform == TargetPlatform.iOS) {
                            try {
                              controller.addJavaScriptHandler(
                                handlerName: 'pickSoundfont',
                                callback: (_) => _pickSoundfontForWebView(controller),
                              );
                            } catch (_) {}
                          }
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
          ],
        ),
      ),
    );
  }
}
