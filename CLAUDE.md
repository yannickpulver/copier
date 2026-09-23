# Copier

Native SwiftUI macOS app. Backs up photos/videos from SD cards to NAS/SSD.

App lives in `macos/` (Tuist 4 project) with core logic in the `macos/CopierCore` Swift package.

## Build & Test

- `cd macos/CopierCore && swift test` — run CopierCore unit tests
- `cd macos && tuist generate --no-open` — generate the Xcode project/workspace (not checked in)
- `xcodebuild -workspace macos/Copier.xcworkspace -scheme Copier build` — build the app

## Releasing (IMPORTANT)

The release workflow (`.github/workflows/release.yml`) triggers on **every push to `main`** and reads the version from the **`VERSION` file**. It creates a GitHub release `v<VERSION>`, builds/signs/notarizes the app, and updates the homebrew tap.

To release, bump `VERSION` (e.g. `2.0.1`); MARKETING_VERSION is read from it by the Tuist manifest. If the tag `v<VERSION>` already exists, the workflow skips the release.

## Sparkle updates

The app updates itself with Sparkle 2. The feed is `releases/latest/download/appcast.xml`: the release workflow signs the zip with the `SPARKLE_PRIVATE_KEY` secret and attaches a one-item `appcast.xml` to every release. The public half is `SUPublicEDKey` in `macos/Project.swift`. The key pair was made once with Sparkle's `generate_keys`. If the private key is lost, installed copies can't take updates anymore, so it's also kept in 1Password. Without the secret, the workflow skips the appcast. `SPARKLE_VERSION` in the workflow should match the SPM version in the manifest.
