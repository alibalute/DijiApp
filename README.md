# eTar Settings – iOS App

iOS app that wraps the eTar Settings web UI (`qui-skinned.html`) in a native shell with Bluetooth LE support, so it can be built on **Codemagic** and run on device.

## Structure

- **eTarSettings/** – Xcode app target
  - `AppDelegate.swift` – App entry point
  - `WebViewController.swift` – WKWebView + CoreBluetooth bridge (replaces Web Bluetooth / Android BLE)
  - `qui-skinned.html` – Bundled web UI (eTar settings)
  - `Info.plist` – App config and `NSBluetoothAlwaysUsageDescription`
  - `LaunchScreen.storyboard`, `Assets.xcassets`
- **eTarSettings.xcodeproj** – Xcode project and shared scheme
- **codemagic.yaml** – Codemagic workflow for building the iOS app

## Building locally

1. Open `eTarSettings.xcodeproj` in Xcode.
2. Select the **eTarSettings** scheme and a simulator or device.
3. Build and run (⌘R).

## Building on Codemagic

1. Push the repo to GitHub/GitLab/Bitbucket and connect it in [Codemagic](https://codemagic.io).
2. The default workflow in `codemagic.yaml` builds the app without code signing (for verification).
3. To produce an installable or App Store build:
   - In Codemagic: **App settings → Code signing**.
   - Add your Apple Developer account, certificates, and provisioning profiles (or use the automatic option).
   - In `codemagic.yaml`, remove the `CODE_SIGN_IDENTITY=""` / `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGNING_ALLOWED=NO` lines so the build uses your signing setup.

## Bluetooth

The app uses **CoreBluetooth** and injects an `AndroidBLE`-compatible bridge into the web view so the existing HTML/JS (written for Web Bluetooth / Android) works on iOS. The eTar service UUID `03B80E5A-EDE8-4B33-A751-6CE34EC4C700` is used for scan and connect.

## Requirements

- Xcode 14+
- iOS 15.0+
- Device with Bluetooth LE (real device for BLE; simulator for UI only)
