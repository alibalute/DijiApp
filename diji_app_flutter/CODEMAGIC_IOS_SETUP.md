# CodeMagic iOS build – code signing setup

The error **"No valid code signing certificates were found"** means CodeMagic has no Apple signing credentials. Fix it using one of the two options below.

**"No matching certificate found for every requested profile"** (with automatic signing): The provisioning profile fetched for your bundle ID is tied to a certificate CodeMagic doesn’t have (e.g. one you created manually). Use **manual** signing: upload that certificate (.p12) and the provisioning profile to CodeMagic, and in `codemagic.yaml` set `provisioning_profiles` and `certificates` to their exact reference names. Ensure the profile in Apple Developer includes that certificate.

**"No Accounts" / "No profiles were found" / "Signing certificate is invalid" during IPA export:** Can occur with manual signing if the export step doesn’t see the keychain. The workflow uses a custom export options plist (with `teamID`, no `signingCertificate`). If it still fails, try automatic signing (Option A) after ensuring the App Store Connect API key can create/fetch distribution certificates.

---

## Option A: Automatic code signing (recommended)

CodeMagic can create and manage certificates and provisioning profiles via the App Store Connect API.

### 1. Create an App Store Connect API key

1. Go to [App Store Connect](https://appstoreconnect.apple.com) → **Users and Access** → **Integrations** → **App Store Connect API**.
2. Create a key with **App Manager** (or **Admin**) role.
3. Download the **.p8 file** once (it cannot be downloaded again).
4. Note:
   - **Issuer ID**
   - **Key ID**

### 2. Add the API key in CodeMagic

1. In [CodeMagic](https://codemagic.io): **Team settings** (or **Personal account** → **Teams**) → **Integrations** → **App Store Connect**.
2. Click **Add integration**.
3. Name it (e.g. `codemagic` – this name is used in `codemagic.yaml` as `app_store_connect: codemagic`).
4. Enter **Issuer ID**, **Key ID**, and upload the **.p8** file.
5. Save.

### 3. Use the integration in your app

- In the CodeMagic **App settings** for this project, open the **iOS** workflow.
- Under **Code signing**, choose the **App Store Connect** integration you created (e.g. `codemagic`).
- If you use `codemagic.yaml`, it already has:
  - `integrations: app_store_connect: codemagic`
  - `ios_signing` with `distribution_type: app_store` and `bundle_identifier: com.example.dijiAppFlutter`

### 4. Bundle ID and app in App Store Connect

- Your app’s bundle ID in Xcode/Flutter must match what you use in CodeMagic (`com.example.dijiAppFlutter` in the current config).
- For **App Store / TestFlight**, the bundle ID must be registered in the [Apple Developer portal](https://developer.apple.com/account) and an app created in [App Store Connect](https://appstoreconnect.apple.com) with that bundle ID.
- If you change the bundle ID (e.g. from `com.example.dijiAppFlutter` to something like `com.yourcompany.etar`), update:
  - Xcode: **Runner** target → **Signing & Capabilities** → Bundle Identifier.
  - `codemagic.yaml`: `ios_signing.bundle_identifier`.

After this, start a new iOS build in CodeMagic; it should create or use the right certificates and profiles automatically.

---

## Option B: Manual code signing

If you prefer not to use the App Store Connect API, you can upload a certificate and provisioning profile.

---

## Create a matching certificate for your profile

Your provisioning profile was created for a specific **type** of certificate. You need to create that certificate, then export it as **.p12** and upload it to CodeMagic.

### Step 1: Match the certificate type to your profile

| Profile type (distribution) | Certificate you need |
|----------------------------|------------------------|
| **App Store** or **TestFlight** | **Apple Distribution** |
| **Ad Hoc** | **Apple Distribution** |
| **Development** | **Apple Development** |

Your profile for `com.example.dijiAppFlutter` with **app_store** → you need an **Apple Distribution** certificate.

### Step 2: Create the certificate (Apple Developer Portal)

1. Go to [developer.apple.com/account](https://developer.apple.com/account) → **Certificates, Identifiers & Profiles** → **Certificates**.
2. Click **+** to add a certificate.
3. Choose:
   - **Apple Distribution** (for App Store / Ad Hoc), or  
   - **Apple Development** (for development only).
4. Click **Continue**, then follow the steps to create a **Certificate Signing Request (CSR)**:
   - On your **Mac**, open **Keychain Access** (Applications → Utilities).
   - Menu **Keychain Access** → **Certificate Assistant** → **Request a Certificate From a Certificate Authority**.
   - Enter your **email** and a **name** (e.g. "CodeMagic iOS"), leave **CA** empty, choose **Saved to disk**.
   - Save the **.certSigningRequest** file.
5. Back in the Developer Portal, **upload** that CSR and click **Continue**.
6. **Download** the generated certificate (e.g. `distribution.cer`) and **double‑click** it to install into your Mac’s Keychain.

### Step 3: Export the certificate as .p12 (on a Mac)

1. Open **Keychain Access** (Applications → Utilities).
2. In the left sidebar, select **login** and **My Certificates** (or search for “Apple Distribution” or “Apple Development”).
3. Find the certificate; it should have a **small triangle** next to it. Expand it — you should see the certificate **and** its **private key**.
4. **Select the certificate** (the line with the cert name, not only the key).
5. **File** → **Export Items** (or right‑click → **Export**).
6. Choose format **Personal Information Exchange (.p12)**.
7. Save the file (e.g. `etar-distribution.p12`) and set a **password** (you’ll need this in CodeMagic).
8. Keep the **.p12** and password safe; upload the **.p12** to CodeMagic (see Option B step 4 below).

**If you don’t have a Mac:** You cannot create or export a .p12 yourself. Use **Option A** (App Store Connect API) so CodeMagic creates and manages the certificate for you, or use a teammate’s Mac once to create and export the .p12.

---

### 1. Create certificate and profile (on a Mac with Xcode)

1. Open the project in Xcode:
   ```bash
   open ios/Runner.xcworkspace
   ```
2. Select the **Runner** target → **Signing & Capabilities**.
3. Choose your **Team** (sign in with your Apple ID if needed).
4. Set a unique **Bundle ID** (e.g. `com.yourcompany.etar`).
5. Enable **Automatically manage signing** and let Xcode create a Development (and optionally Distribution) certificate and provisioning profile.

### 2. Export the signing certificate (.p12)

1. Open **Keychain Access** on your Mac.
2. Find your **Apple Development** or **Apple Distribution** certificate (and its private key).
3. Right‑click → **Export** → save as **.p12** and set a password.

### 3. Get the provisioning profile

- **Development:** Xcode → **Runner** → **Signing & Capabilities** → **Download Manual Profiles**, or download from [Apple Developer](https://developer.apple.com/account/resources/profiles/list).
- **Distribution (App Store / Ad Hoc):** Create in [Developer Portal](https://developer.apple.com/account/resources/profiles/add) and download the **.mobileprovision** file.

### 4. Upload to CodeMagic

1. CodeMagic → **Team settings** → **Code signing identities**.
2. **iOS** → **Add certificate**:
   - Upload the **.p12** file.
   - Enter the **.p12 password**.
   - Give it a **reference name** (e.g. `ios-distribution`).
3. **iOS** → **Add provisioning profile**:
   - Upload the **.mobileprovision** file.
   - Give it a **reference name** (e.g. `etar-app-store`).

### 5. Point the workflow to these

In your iOS workflow in CodeMagic (or in `codemagic.yaml`), set the **Certificate** and **Provisioning profile** to these reference names. If you use only the CodeMagic UI (no YAML), select the uploaded certificate and profile in the workflow’s **Code signing** section.

If you use `codemagic.yaml`, you can reference them like this (names must match what you set in CodeMagic):

```yaml
environment:
  ios_signing:
    distribution_type: app_store
    bundle_identifier: com.example.dijiAppFlutter
    certificate: ios-distribution      # reference name of your .p12
    provisioning_profile: etar-app-store  # reference name of your .mobileprovision
```

---

## Troubleshooting: "exportArchive: Signing certificate is invalid"

If the **archive** step succeeds but **Building App Store IPA** fails with:

```
Encountered error while creating the IPA:
error: exportArchive Signing certificate is invalid.
```

the export step is rejecting your signing certificate. Try the following.

### 1. Certificate and profile must match

- The **provisioning profile** must include the **exact same certificate** you uploaded to CodeMagic.
- In [Apple Developer → Profiles](https://developer.apple.com/account/resources/profiles/list), open your App Store profile for `com.example.dijiAppFlutter`, check which **certificate** it uses, then ensure that certificate (and only that one) is the one you exported as .p12 and uploaded to CodeMagic.
- If you created a **new** Distribution certificate later, **edit the profile** in the Developer Portal, select that new certificate, save, **download the updated .mobileprovision**, and **re-upload** it to CodeMagic (same reference name or update `codemagic.yaml`).

### 2. Certificate must be valid

- In [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list), confirm your **Apple Distribution** certificate is **Valid**, not expired or revoked.
- If it is expired or revoked, create a new Apple Distribution certificate, export it as .p12, upload the new .p12 to CodeMagic, and **regenerate the provisioning profile** to use the new certificate, then re-upload the profile.

### 3. Re-export the .p12 correctly

- On your Mac, open **Keychain Access** → **Login** → **My Certificates**.
- Select the **Apple Distribution** certificate (the one that has a **private key** under it — expand the row to confirm).
- **File → Export Items** → format **Personal Information Exchange (.p12)**, set a password, and save.
- In CodeMagic **Team settings → Code signing identities → iOS**, **remove** the old certificate and **upload** this new .p12 (with the same password you set). Use the same reference name as in `codemagic.yaml`.

### 4. Use automatic code signing (Option A)

- Manual certificate/profile mismatches often cause this error. Switching to **Option A** (App Store Connect API key) lets CodeMagic create and use matching certificates and profiles, which usually resolves "Signing certificate is invalid."

### 5. Export options plist (teamID, no `signingCertificate`)

- The workflow **creates its own** `export_options.plist` with **method**, **teamID**, and **provisioningProfiles** (it does **not** set `signingCertificate`). That way Xcode picks the certificate that matches your profile from the keychain, which often fixes "Signing certificate is invalid" when CodeMagic’s default plist pointed at the wrong identity.
- **Team ID:** Set **`TEAM_ID`** in the workflow vars to your Apple Developer Team ID (10 characters). Find it at developer.apple.com/account → Membership. If you see "No Team Found in Archive", set `TEAM_ID` explicitly; the script may otherwise auto-detect it from your provisioning profile.
- The script auto-detects the provisioning profile **Name** from the profiles CodeMagic installed. If export still fails, set the env var **`EXPORT_PROFILE_NAME`** in the workflow to the exact **Name** from your `.mobileprovision` (open the file in TextEdit and look for `<key>Name</key><string>…</string>`, or run `security cms -D -i YourProfile.mobileprovision` and check the `Name` value).

### 6. Export method (Xcode 14.3+)

- The custom export plist uses **method** `app-store-connect`. If you use a very old or very new Xcode image, the exact method name might differ; check [CodeMagic Xcode release notes](https://docs.codemagic.io/specs/versions-macos-xcode/) if the error persists.

---

## Build only for simulator (no code signing)

To confirm the project builds on CodeMagic without dealing with signing:

- Use the **iOS Simulator** workflow in `codemagic.yaml` (`ios-simulator-workflow`), which runs:
  ```bash
  flutter build ios --simulator --no-codesign
  ```
- Or in the CodeMagic UI, add a workflow that builds for the iOS simulator only (no device/App Store signing).

---

## References

- [CodeMagic iOS code signing](https://docs.codemagic.io/flutter-code-signing/ios-code-signing/)
- [CodeMagic YAML – signing iOS](https://docs.codemagic.io/yaml-code-signing/signing-ios/)
- [Apple: Maintaining certificates](https://developer.apple.com/library/content/documentation/IDEs/Conceptual/AppDistributionGuide/MaintainingCertificates/MaintainingCertificates.html)
