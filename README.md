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

---

## See the app in a simulator (no Xcode): Codemagic + Appetize

Use this when you don’t have Xcode: build the app in the cloud, then run it in a browser-based iOS simulator.

### Step 1: Connect the repo to Codemagic

1. Go to [codemagic.io](https://codemagic.io) and sign in (GitHub/GitLab/Bitbucket).
2. Click **Add application** and choose **Add repository**.
3. Select this repo and finish the wizard (no need to add code signing for the simulator build).

### Step 2: Run the simulator workflow

1. In Codemagic, open your app and go to **Workflows**.
2. Start the workflow **eTar Settings (simulator → Appetize)** (the `ios-simulator` workflow in `codemagic.yaml`).
3. Wait for the build to finish.
4. In the build summary, open **Artifacts** and download **eTarSettings-simulator.zip**.

### Step 3: Upload to Appetize.io

1. Go to [appetize.io](https://appetize.io) and sign up or log in (free tier is enough).
2. Click **Upload** (or **New app**).
3. Upload the **eTarSettings-simulator.zip** you downloaded from Codemagic.  
   (Appetize accepts a zip containing the `.app` bundle; this zip is in the right format.)
4. Choose **iOS** and the device type (e.g. iPhone or iPad), then start the upload.

### Step 4: Open the app in the browser

1. When the upload finishes, Appetize shows a link (e.g. `https://appetize.io/app/xxxxx`).
2. Open that link in your browser.
3. The app runs in the in-browser iOS simulator. You can tap and scroll; Bluetooth will not work in the simulator.

**Summary:** Codemagic builds the simulator `.app` and zips it → you download the zip → you upload the zip to Appetize → you open the Appetize link to see the app in a simulator in your browser.

## Bluetooth

The app uses **CoreBluetooth** and injects an `AndroidBLE`-compatible bridge into the web view so the existing HTML/JS (written for Web Bluetooth / Android) works on iOS. The eTar service UUID `03B80E5A-EDE8-4B33-A751-6CE34EC4C700` is used for scan and connect.

## Requirements

- Xcode 14+
- iOS 15.0+
- Device with Bluetooth LE (real device for BLE; simulator for UI only)
