# Folder Sync Target Simplification

**Date:** 2026-07-12
**Status:** Approved

## Problem

Folder sync target resolution got too complex: `resolveSyncTarget` compares source/target basenames and auto-appends the source name unless they match, with an inline "sync into subfolder instead / directly" toggle link (`syncTargetExact`) plus a legacy `syncExactDest` migration.

## Solution

Replace the magic with one explicit checkbox.

### UI (sync tab)

- Keep: source drop zone, destination dropdown (saved destinations, shared with transfer tab), drag-drop transient target, browse/+ button.
- Add: checkbox under the destination row — **"Append source folder name"**, default checked.
- Remove: the inline exact-toggle link in the dest hint. Hint just shows the resolved path (`→ parent/folder/`).

### Logic

`resolveSyncTarget(sourcePath, targetPath, append)`:

- `append === true` → `<targetPath>/<source basename>`
- `append === false` → `targetPath` as-is
- No basename-comparison guard. If the target is already named like the source and the box is checked, the result is `target/name/name` — visible in the hint, user's choice.

### Settings

- New key: `syncAppendSourceName` (boolean).
- On load: if unset, migrate from old `syncTargetExact` (`append = !exact`); otherwise default `true`.
- Remove the `syncExactDest` legacy migration (dead code from an already-removed UI).

### Tests

Rewrite `src/lib/syncTarget.test.ts` for the two-branch behavior (append on/off, trailing-slash handling, empty target).
