# Copier

Electron app. Backs up photos/videos from SD cards to NAS/SSD.

## Releasing (IMPORTANT)

The release workflow (`.github/workflows/release.yml`) triggers on **every push to `main`** and reads the version from the **`VERSION` file** — NOT `package.json`. It creates a GitHub release `v<VERSION>` and updates the homebrew tap.

When bumping the version, **always update `VERSION`** (and keep `package.json` in sync). If only `package.json` is bumped, the workflow re-reads the old `VERSION`, the tag already exists, and no release is published. This already happened with v1.3.4 (committed but never released).

Bump both:
- `VERSION` → e.g. `1.3.5`
- `npm version <v> --no-git-tag-version --allow-same-version`
