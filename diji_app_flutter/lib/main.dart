import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:diji_app_flutter/screens/android_webview_screen.dart';
import 'package:diji_app_flutter/screens/web_screen.dart';

// Brand colors
const Color _brandPurple = Color(0xFF482C76);
const Color _brandTeal = Color(0xFF20767A);
const Color _brandDark = Color(0xFF1F2933);
const Color _brandGold = Color(0xFFEEA803);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DijiApp());
}

class DijiApp extends StatelessWidget {
  const DijiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DijiApp',
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: _brandPurple,
          onPrimary: Colors.white,
          secondary: _brandTeal,
          onSecondary: Colors.white,
          tertiary: _brandGold,
          onTertiary: _brandDark,
          surface: _brandDark,
          onSurface: Colors.white,
          error: const Color(0xFFCF6679),
          onError: Colors.black,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: _brandDark,
        appBarTheme: const AppBarTheme(
          backgroundColor: _brandPurple,
          foregroundColor: Colors.white,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: _brandGold,
          circularTrackColor: _brandTeal,
        ),
      ),
      home: defaultTargetPlatform == TargetPlatform.android
          ? const AndroidWebViewScreen()
          : const WebScreen(),
    );
  }
}
