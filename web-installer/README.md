# NeoStation iOS — Private Web Installer

This folder contains a small private OTA installation portal intended for iPhone/iPad browsers.

## What it does

- Protects the landing page with HTTP Basic Auth.
- Marks every route `noindex` / `nofollow` / `noarchive`.
- Generates the Apple OTA `manifest.plist` dynamically.
- Uses a long install token because the iOS installation service fetches the manifest and IPA outside the browser page itself.
- Redirects the token-protected `/app.ipa` endpoint to the configured signed IPA URL.

## Important signing limitation

The GitHub Actions IPA produced by NeoStation's current `feature/library-native` workflow is **unsigned**. An unsigned IPA cannot be installed by the web button.

For OTA installation, configure `IPA_SOURCE_URL` with an **already signed** IPA that the target device is allowed to install. The IPA and manifest must be reachable over HTTPS. Apple documents website-based installation using a manifest and a trusted signed app; distribution/profile requirements depend on the signing/distribution method being used.

## Deploy on Vercel

1. Import `TarbleFR/neostation-ios` into Vercel.
2. Select branch `feature/private-web-installer`.
3. Set **Root Directory** to `web-installer`.
4. Add the environment variables listed in `.env.example`.
5. Deploy.
6. Open the resulting HTTPS URL from Chrome or Safari on the iPhone.
7. Enter the Basic Auth username/password.
8. Tap **Installer NeoStation iOS**.

## Environment variables

- `INSTALLER_USER`: private page login.
- `INSTALLER_PASSWORD`: private page password. Use a strong random value.
- `INSTALL_TOKEN`: at least 32 random characters. This protects manifest/IPA endpoints used outside the browser auth session.
- `IPA_SOURCE_URL`: direct HTTPS URL to a signed NeoStation IPA.
- `APP_TITLE`: defaults to `NeoStation iOS`.
- `APP_BUNDLE_ID`: defaults to `com.neogamelab.neostation`.
- `APP_VERSION`: version string inserted in the manifest.
- `BUILD_LABEL`: text shown on the private portal.

## Security model

The page itself is server-side password protected. The manifest and `/app.ipa` route use a separate opaque token because iOS may fetch installation resources independently of the browser's Basic Auth session.

The final `IPA_SOURCE_URL` must remain reachable by the iOS installation service. For stronger control, use an HTTPS object-storage URL with a long unguessable path or another distribution backend designed to serve the signed IPA. Do not commit certificates, provisioning profiles, passwords, tokens, or signing keys to this repository.

## Routes

- `/` — authenticated private installer page.
- `/manifest.plist?token=...` — token-gated Apple OTA manifest.
- `/app.ipa?token=...` — token-gated redirect to `IPA_SOURCE_URL`.

## Chrome on iOS

The page itself is standard HTTPS and works in iOS browsers. The install button uses Apple's `itms-services://` handoff. If an iOS browser refuses to hand off that custom scheme, open the same private URL in Safari and retry.
