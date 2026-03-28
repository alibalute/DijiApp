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
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  return NavigationActionPolicy.CANCEL;
}
