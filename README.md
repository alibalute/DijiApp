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
2. The **eTar Settings (device)** workflow builds the app without code signing (for verification).
3. To produce an installable IPA for iPad, follow **How to build an IPA for iPad** below.

---

## How to build an IPA for iPad with Codemagic

End-to-end steps to get an IPA you can install on your iPad.

### 1. Apple Developer setup (one-time)

- Have an **Apple Developer Program** account ([developer.apple.com](https://developer.apple.com/programs/)).
- **App ID:** In Developer Portal → **Identifiers** → create an App ID with bundle ID **`com.dijilele.eTarSettings`** (or match the one in `codemagic.yaml` and the Xcode project).
- **Register your iPad:** **Devices** → add your iPad (you need its **UDID** from Settings → General → About, or from Finder when connected to a Mac).
- **Certificate:** In **Certificates** create or use an **Apple Distribution** certificate. Export it as a **.p12** from Keychain Access (right‑click the cert → Export) and set a password.
- **Ad Hoc profile:** See **Create an Ad Hoc provisioning profile** below.

### 2. Add signing files to Codemagic (one-time)

- In [Codemagic](https://codemagic.io): **Team settings** (gear) → **Code signing identities**.
- **iOS certificates:** **Add certificate** → upload your **.p12** → enter the password → set a reference name (e.g. `ios_distribution`).
- **iOS provisioning profiles:** **Add profile** → upload your **Ad Hoc .mobileprovision** → set a reference name (e.g. `etar_ad_hoc`).

### 3. Connect the repo and run the IPA workflow

- **Applications** → **Add application** → connect the **eTarSettings** repo (if not already added).
- Open the app → **Workflows**.
- Run the workflow **eTar Settings (Ad Hoc IPA)** (the `ios-adhoc` workflow in `codemagic.yaml`).
- Wait for the build to finish.

### 4. Download the IPA and install on iPad

- In the build page, open **Artifacts**.
- Download the **.ipa** file (e.g. `eTarSettings.ipa`).
- **Install on iPad:**  
  - **Option A:** Upload the IPA to [Diawi](https://www.diawi.com), open the link on your iPad in Safari, and tap Install.  
  - **Option B:** Copy the IPA to a Mac, connect the iPad, open **Finder** → select the iPad → drag the IPA into the list of apps (or use Apple Configurator).

After installation, trust the developer in **Settings → General → VPN & Device Management** if prompted.

---

## Create an Ad Hoc provisioning profile

Do this in the [Apple Developer Portal](https://developer.apple.com/account) (you need an Apple Developer Program account).

### 1. Get your iPad’s UDID

- **On iPad:** **Settings** → **General** → **About** → scroll to **UDID** (tap to copy if shown).
- **Or with a Mac:** Connect the iPad → open **Finder** → select the iPad → click the device name under the sidebar until it shows “UDID” and copy it.

### 2. Register the iPad as a device

- In the Developer Portal go to **Certificates, Identifiers & Profiles** → **Devices**.
- Click the **+** button.
- **Name:** e.g. “My iPad”.
- **UDID:** paste the UDID from step 1.
- Click **Continue** → **Register**.

### 3. Create an App ID (if you don’t have one)

- Go to **Identifiers** → **+**.
- Choose **App IDs** → **App** → **Continue**.
- **Description:** e.g. “eTar Settings”.
- **Bundle ID:** choose **Explicit** and enter: **`com.dijilele.eTarSettings`** (must match the app).
- Under **Capabilities**, enable **Bluetooth** (or any others your app needs).
- **Continue** → **Register**.

### 4. Create an Apple Distribution certificate (if you don’t have one)

- Go to **Certificates** → **+**.
- Under **Distribution**, select **Apple Distribution** → **Continue**.
- Create a **Certificate Signing Request (CSR)** on your Mac:
  - Open **Keychain Access** → menu **Keychain Access** → **Certificate Assistant** → **Request a Certificate From a Certificate Authority**.
  - Email: your email. **Common Name:** your name. Select **Saved to disk** → **Continue** and save the `.certSigningRequest` file.
- Back in the portal, upload that `.certSigningRequest` → **Continue** → **Download** the certificate (`.cer`).
- Double‑click the downloaded `.cer` to add it to your Mac’s Keychain. Then export it as `.p12` (see **Export Apple Distribution certificate as .p12** below).

### 5. Create the Ad Hoc provisioning profile

- Go to **Profiles** → **+**.
- Under **Distribution**, select **Ad Hoc** → **Continue**.
- **App ID:** select the App ID you use for eTar Settings (e.g. **com.dijilele.eTarSettings**) → **Continue**.
- **Certificates:** select your **Apple Distribution** certificate → **Continue**.
- **Devices:** select the iPad(s) you want to install the app on (e.g. “My iPad”) → **Continue**.
- **Profile name:** e.g. “eTar Settings Ad Hoc” → **Generate**.
- Click **Download** to save the **.mobileprovision** file.

That `.mobileprovision` file is the Ad Hoc provisioning profile. Upload it in Codemagic under **Team settings** → **Code signing identities** → **iOS provisioning profiles** → **Add profile**.

---

## Export Apple Distribution certificate as .p12 from Keychain

Do this on a Mac after you’ve installed the Apple Distribution certificate (e.g. by double‑clicking the `.cer` from the Developer Portal).

### 1. Open Keychain Access

- Press **⌘ + Space**, type **Keychain Access**, press Enter.

### 2. Find the certificate

- In the left sidebar, select **login** (or **System**) and the **Certificates** category.
- In the list, find **Apple Distribution: Your Name (XXXXXXXX)** or **iPhone Distribution: …** (the one for your team).
- If you don’t see it, make sure **Certificates** is selected and that you’ve double‑clicked the `.cer` file to install it.

### 3. Export as .p12

- **Right‑click** (or Control‑click) the **Apple Distribution** certificate.
- Choose **Export “Apple Distribution: …”** (or **Export “iPhone Distribution: …”**).
- Pick a location and name (e.g. `distribution.p12`) → **Save**.

### 4. Set the password

- When prompted for a **password**, enter a strong password (you’ll need this in Codemagic).
- Re-enter it to confirm.
- Click **OK**. If asked for your **Mac login password**, enter it so Keychain can export the private key.

You now have a **.p12** file. Upload it in Codemagic under **Team settings** → **Code signing identities** → **iOS certificates** → **Add certificate**, and enter the same password you set here.

**If “Export” or .p12 is greyed out:**

- The **private key** for this certificate must be in the same Keychain. The certificate from Apple is only half of the pair; the private key was created on this Mac when you made the CSR. If you created the CSR on **this Mac**, the key should be here.
- **Try:** In Keychain Access, select **login** (or **System**) and **Certificates**. Expand the **Apple Distribution** entry (click the triangle). You should see the certificate and a **Private Key** under it. Select the **certificate** line (the parent, not the key), then right‑click → **Export**.
- **If the certificate has no private key under it:** The cert was likely installed from another Mac or the key was deleted. You can’t export a .p12 without the private key. In that case, create a **new** Apple Distribution certificate in the Developer Portal (you may need to revoke the old one first), create a new CSR on **this** Mac, download the new .cer, install it, then export that one as .p12.
- **If Keychain asks for “Allow access” when exporting:** Enter your Mac login password so it can read the private key.

---

## Ad Hoc build on Codemagic (IPA for iPad) – reference

To build a signed IPA and install it on your iPad without Xcode, use the **device workflow with code signing** and the **Ad Hoc** profile.

### Where to set it in Codemagic

**1. Upload certificate and Ad Hoc profile (one-time)**

- In Codemagic, open **Team settings** (gear icon or your team name).
- Go to **Code signing identities** (or **codemagic.yaml** → **Code signing**).
- **iOS certificates:** Click **Add certificate** → upload your **Apple Distribution** `.p12` file, set a password if needed, and give it a **Reference name** (e.g. `ios_distribution`).
- **iOS provisioning profiles:** Click **Add profile** → upload your **Ad Hoc** `.mobileprovision` file and give it a **Reference name** (e.g. `etar_ad_hoc`).

**2. Tell the workflow to use Ad Hoc**

- In your **application** (not Team), open **Workflows** and select the workflow that should produce the IPA (e.g. **eTar Settings (Ad Hoc IPA)**).
- The workflow is already set in `codemagic.yaml` to use **Ad Hoc** and your app’s bundle ID:
  - `environment.ios_signing.distribution_type: ad_hoc`
  - `environment.ios_signing.bundle_identifier: com.dijilele.eTarSettings`
- Codemagic will match the uploaded Ad Hoc profile and distribution certificate to this bundle ID when you run the workflow. You don’t select the profile in the UI per run; the **workflow** is configured in YAML and the **files** are in Team → Code signing identities.

**3. Run the workflow**

- Start the **eTar Settings (Ad Hoc IPA)** workflow.
- After the build, download the **IPA** from **Artifacts** and install it on your iPad (e.g. via Diawi, or by copying to a Mac and installing via Finder).

**Summary:** Upload the **certificate** and **Ad Hoc provisioning profile** under **Team settings → Code signing identities**. The **eTar Settings (Ad Hoc IPA)** workflow in `codemagic.yaml` uses `distribution_type: ad_hoc` and `bundle_identifier: com.dijilele.eTarSettings`, so Codemagic will pick the matching profile and certificate and produce an IPA. The IPA is in the build **Artifacts**.

**"No matching profiles found" error:** The Ad Hoc profile you uploaded must have **exactly** the bundle identifier `com.dijilele.eTarSettings`. In [Apple Developer Portal](https://developer.apple.com/account/resources/identifiers/list) → **Profiles**, create an **Ad Hoc** profile for an App ID with that bundle ID (create the App ID first under **Identifiers** if needed), then download the `.mobileprovision` and upload it in Codemagic **Team settings → Code signing identities**. If your profile uses a different bundle ID, change `bundle_identifier` in `codemagic.yaml` and `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project to match it.

**"No matching certificate found for every requested profile" error:** Your Ad Hoc profile was created with a specific **Apple Distribution** certificate. Codemagic must have that **same** certificate (as a `.p12` file) in **Team settings → Code signing identities → iOS certificates**. Export the certificate from the Mac where you created it (Keychain Access → find "Apple Distribution: …" → right‑click → Export → save as `.p12` and set a password), then upload that `.p12` in Codemagic and enter the password. The certificate in Codemagic must be the one that is associated with your Ad Hoc profile in the Apple Developer Portal.

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
