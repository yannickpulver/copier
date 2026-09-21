# Copier

Native SwiftUI macOS app. Backs up photos/videos from SD cards to NAS/SSD.

App lives in `macos/` (Tuist 4 project) with core logic in the `macos/CopierCore` Swift package. `src/` holds the legacy Electron app, kept for reference but no longer released.

## Build & Test

- `cd macos/CopierCore && swift test` — run CopierCore unit tests
- `cd macos && tuist generate --no-open` — generate the Xcode project/workspace (not checked in)
- `xcodebuild -workspace macos/Copier.xcworkspace -scheme Copier build` — build the app

## Releasing (IMPORTANT)

The release workflow (`.github/workflows/release.yml`) triggers on **every push to `main`** and reads the version from the **`VERSION` file** — NOT `package.json`. It creates a GitHub release `v<VERSION>`, builds/signs/notarizes the app, and updates the homebrew tap.

When bumping the version, **always update `VERSION`** (MARKETING_VERSION is read from it by the Tuist manifest). If only `package.json` is bumped, the workflow re-reads the old `VERSION`, the tag already exists, and no release is published. This already happened with v1.3.4 (committed but never released).

Bump:
- `VERSION` → e.g. `2.0.1`
- `package.json` `version` field, to keep it in sync (no functional effect on the release, but avoid drift)
