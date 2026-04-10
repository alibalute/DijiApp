import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens http(s) links in the system browser; keeps file:// and other schemes in the WebView.
Future<NavigationActionPolicy?> openExternalHttpInSystemBrowser(
  InAppWebViewController controller,
  NavigationAction navigationAction,
) async {
  final webUri = navigationAction.request.url;
  if (webUri == null) return NavigationActionPolicy.ALLOW;
  final uri = Uri.tryParse(webUri.toString());
  if (uri == null) return NavigationActionPolicy.ALLOW;
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return NavigationActionPolicy.ALLOW;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '[::1]' ||
      host.endsWith('.localhost')) {
    return NavigationActionPolicy.ALLOW;
  }
  /* ESP32 instrument Wi‑Fi AP OTA UI — must load inside the WebView (in-app iframe). */
  if (host == '192.168.4.1') {
    return NavigationActionPolicy.ALLOW;
  }
  /* Iframe/subframe navigations must not be cancelled or we open Safari for the child URL
     (e.g. OTA page) and the iframe stays blank — especially on iOS WKWebView. */
  if (!navigationAction.isForMainFrame) {
    return NavigationActionPolicy.ALLOW;
  }
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  return NavigationActionPolicy.CANCEL;
}
