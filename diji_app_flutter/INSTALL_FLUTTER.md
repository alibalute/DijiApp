# Install Flutter on Windows

## Option 1: Winget (recommended)

1. Open **PowerShell** or **Terminal** (as a normal user is fine).
2. Run:
   ```powershell
   winget install Flutter.Flutter --accept-source-agreements --accept-package-agreements
   ```
3. **Close and reopen** your terminal (or restart the PC) so `PATH` is updated.
4. Verify:
   ```powershell
   flutter doctor
   ```

## Option 2: Manual install

1. **Download:** [flutter.dev/docs/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows) — get the latest **Stable** ZIP.
2. **Extract** to a folder without spaces or special characters (e.g. `C:\flutter`). Do **not** put it under `C:\Program Files`.
3. **Add to PATH:**
   - Press **Win + R**, type `sysdm.cpl`, Enter.
   - **Advanced** tab → **Environment Variables**.
   - Under **User variables**, select **Path** → **Edit** → **New** → add the path to the **`flutter\bin`** folder (e.g. `C:\flutter\bin`) → **OK**.
4. **Close and reopen** the terminal, then run:
   ```powershell
   flutter doctor
   ```

## After installing

- Fix any issues reported by `flutter doctor` (e.g. install Android Studio or Visual Studio for the platforms you need).
- For **DijiApp**, generate platform folders if needed:
  ```powershell
  cd path\to\diji_app_flutter
  flutter create . --project-name diji_app_flutter
  flutter pub get
  flutter run
  ```

**Note:** Building for **iOS** requires a Mac with Xcode. On Windows you can build and run the **Android** app and use **Chrome** for the web target.

---

## Run the Flutter app in Chrome

From the project folder:

```powershell
cd path\to\diji_app_flutter
flutter pub get
flutter run -d chrome
```

Or run `flutter run` and choose **Chrome** from the list when Flutter asks which device to use.

**Note:** **DijiApp** uses a WebView and BLE. In Chrome (web), the WebView is your page and BLE may not work the same as on a device; use Chrome mainly to see the UI. For full BLE, run on a real Android device or iOS device/simulator.

### If Chrome shows a blank screen

1. **Clean and run again:**
   ```powershell
   cd path\to\diji_app_flutter
   flutter clean
   flutter pub get
   flutter run -d chrome
   ```

2. **Confirm `web/index.html`** includes the InAppWebView web script (it should have a line with `flutter_inappwebview_web` and `web_support.js`). Without it, the WebView can stay blank on web.

3. **Open the HTML directly in Chrome** to at least see the UI: run the app, then in the address bar go to the same origin and path, e.g. `http://localhost:XXXXX/assets/qui-skinned.html` (replace XXXXX with the port Flutter shows when you run). That loads the DijiApp page without the Flutter shell.
