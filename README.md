# Microphone Control for macOS

Microphone Control is a small menu-bar app that lets supported headphone mute gestures control the active macOS microphone. It keeps an input-only audio session open so macOS can route the hardware mute gesture to the app, then applies the mute state to the system input device.

## Privacy

The app opens the selected microphone while it is running, but every audio buffer is discarded immediately in memory. It does not record, save, analyze, upload, or transmit audio. macOS displays its microphone privacy indicator while the app is active.

## Install

> The current preview artifact is anonymously ad-hoc signed and is not notarized. It works for local validation, but Gatekeeper may block it after download on another Mac. For distribution without security warnings, the distributor must rebuild it with an organization-controlled Developer ID certificate and notarize it with Apple.

1. Open the release disk image.
2. Open **Install Microphone Control** and choose **Install**.
3. Allow microphone access when macOS asks.
4. If macOS opens **Login Items**, allow Microphone Control to run in the background.

The app installs only for the current user in the user Applications folder. Its macOS-managed background service starts after login, stays available before calling apps open, and restarts the helper if it exits unexpectedly. A process lock prevents duplicate helpers.

To disable it later, open the menu-bar item, turn off **Start Automatically**, then choose **Quit Microphone Control**. You can also manage background permission in **System Settings > General > Login Items**.

## Compatibility

- macOS 14 or later
- A headphone model and macOS version that support hardware press-to-mute gestures

Hardware gesture routing is controlled by macOS and may vary by device, firmware, and the active calling app.

## Build from source

Requirements: Xcode Command Line Tools with Swift 6 or later.

```sh
swift build
./script/build_and_run.sh --verify
```

Create release archives:

```sh
./script/package_release.sh
```

The default release is ad-hoc signed. It is suitable for local validation but is not trusted or notarized for frictionless installation on other Macs.

For public distribution, use an organization-controlled **Developer ID Application** certificate:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Organization Name (TEAMID)" ./script/package_release.sh
NOTARY_PROFILE="notary-profile" ./script/notarize_release.sh .artifacts/release/Microphone-Control-0.1.0.dmg
```

The signing certificate and notarization profile must belong to the distributor. Never commit signing identities, credentials, keychain profiles, or notarization output.

## Startup architecture

The app uses Apple's `SMAppService` API to register the bundled per-user LaunchAgent in `Contents/Library/LaunchAgents`. The service is limited to the logged-in Aqua session, uses `RunAtLoad` and `KeepAlive`, and launches the app through the bundle-relative `BundleProgram` path. It does not install a system daemon, request administrator access, or use UI automation.

## License

Microphone Control is available under the [MIT License](LICENSE). You may inspect, modify, redistribute, and build on the source under its terms.
