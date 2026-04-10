import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

/// Website + Instagram as native widgets (not HTML).
/// Must sit in a [Column] above the WebView — iOS WKWebView platform views often cover
/// widgets stacked *on top of* the WebView in a [Stack].
///
/// Instagram uses a bundled SVG (not an icon font) so Android/iOS render the same glyph.
class TopLinksStrip extends StatelessWidget {
  const TopLinksStrip({super.key, this.onFirmwareUpdate});

  /// Shown on web + iOS/Android native when [onFirmwareUpdate] is set (web has no BLE).
  final VoidCallback? onFirmwareUpdate;

  static final Uri _website = Uri.parse('https://www.dijilele.com/');
  static final Uri _instagram = Uri.parse('https://www.instagram.com/dijilele/');

  Future<void> _open(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showOta = onFirmwareUpdate != null &&
        (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    return Material(
      type: MaterialType.transparency,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showOta) ...[
            _LinkCircle(
              tooltip: 'Firmware update (WiFi)',
              onTap: onFirmwareUpdate!,
              child: const Icon(
                Icons.system_update_alt,
                size: 22,
                color: _LinkCircle.accent,
              ),
            ),
            const SizedBox(width: 8),
          ],
          _LinkCircle(
            tooltip: 'dijilele.com',
            onTap: () => _open(_website),
            child: const Icon(Icons.public, size: 22, color: _LinkCircle.accent),
          ),
          const SizedBox(width: 8),
          _LinkCircle(
            tooltip: 'Instagram',
            onTap: () => _open(_instagram),
            child: SvgPicture.asset(
              'assets/icons/instagram.svg',
              width: 22,
              height: 22,
              colorFilter: const ColorFilter.mode(_LinkCircle.accent, BlendMode.srcIn),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkCircle extends StatelessWidget {
  const _LinkCircle({
    required this.child,
    required this.tooltip,
    required this.onTap,
  });

  final Widget child;
  final String tooltip;
  final VoidCallback onTap;

  static const Color accent = Color(0xFFEEA803);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2A3440),
            border: Border.all(color: accent.withValues(alpha: 0.85), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
