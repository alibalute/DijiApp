# DijiApp – Flutter app

Flutter app that wraps **qui-skinned.html** in a WebView and provides a BLE bridge so the same UI works on iOS and Android. The HTML expects `window.AndroidBLE`; the app injects it and implements it using **flutter_blue_plus**.

## Setup

1. **Install Flutter** ([flutter.dev](https://flutter.dev)) and ensure `flutter doctor` passes.

2. **Generate platform folders** (if `android/` and `ios/` are missing):
   ```bash
   cd diji_app_flutter
   flutter create . --project-name diji_app_flutter
   ```
   This adds `android/` and `ios/` without overwriting your `lib/` or `assets/`.

3. **Android – BLE permissions**  
   In `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`, add:
   ```xml
   <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
   ```
   In `android/app/build.gradle`, set `minSdkVersion` to at least **21** (e.g. `minSdkVersion 21`).

4. **iOS – Bluetooth usage**  
   In `ios/Runner/Info.plist`, add:
   ```xml
   <key>NSBluetoothAlwaysUsageDescription</key>
   <string>DijiApp needs Bluetooth to connect to your device.</string>
   ```
   And in **Capabilities** (Xcode) enable **Bluetooth** or ensure `bluetooth-le` is in `UIRequiredDeviceCapabilities`.

## Run

```bash
cd diji_app_flutter
flutter pub get
flutter run
```

Choose a connected device or simulator. BLE only works on a real device.

## Change app icon (home screen)

1. Add your logo as **`assets/app_icon.png`** (square, **1024×1024 px** recommended).
2. Run:
   ```bash
   dart run flutter_launcher_icons
   ```
   This updates the app icon for both iOS and Android.

## Change homepage logo (inside the app)

The logo at the top of the settings screen is loaded from **`assets/logo.png`**.

1. Add your image as **`assets/logo.png`** (e.g. **200×128 px** or similar ratio; it’s shown at 100×64 px).
2. Register it in **`pubspec.yaml`** under `flutter.assets`:
   ```yaml
   assets:
     - assets/qui-skinned.html
     - assets/logo.png
   ```
3. Run the app again. If `logo.png` is missing, a default graphic is shown instead.

## Build

- **Android APK:** `flutter build apk`
- **iOS:** `flutter build ios` (then open `ios/Runner.xcworkspace` in Xcode to archive)
- **Codemagic:** Add a Flutter workflow; point to this app and run `flutter build apk` or `flutter build ios` as needed.

## Structure

- **lib/main.dart** – App entry.
- **lib/screens/web_screen.dart** – Full-screen WebView, injects `AndroidBLE` at document start, handles BLE calls from the page.
- **lib/ble/ble_bridge.dart** – BLE implementation (scan, connect, write, notifications) using flutter_blue_plus; service UUID `03b80e5a-ede8-4b33-a751-6ce34ec4c700`.
- **assets/qui-skinned.html** – Bundled web UI.

The HTML uses `navigator.bluetooth` when `window.AndroidBLE` is present; the bridge provides that interface so the existing UI works unchanged.
