# Folder Sync: Structure-Independent Presence Check

**Date:** 2026-07-11
**Status:** Approved

## Goal

In the Folder Sync tab, answer: "does every file in my source folder exist somewhere in the target folder?" — regardless of subfolder structure on either side. Source files may be nested while target is flat, or vice versa. Additionally, sync macOS Finder tags from source to target.

## Target selection

- Default unchanged: effective target is `<dest>/<source folder name>`, or the dest itself when its last path segment already equals the source folder name.
- New: an explicit "use this exact folder" browse control next to the dest dropdown. When set, that folder is used verbatim as the target (no name appending) — for source/target folders that are not named the same. Clearing it falls back to the default.

## Matching rules (`diffFolders` in `src/lib/sync.ts`)

A source file is compared against **all** files in the target tree, indexed by filename:

| Condition | Bucket |
|---|---|
| Same name **and** same byte size exists anywhere in target | **Present** |
| Same name exists, but no candidate with matching size | **Different** |
| No file with that name anywhere in target | **Missing** |

- Modification time is no longer considered (removes false "changed" flags from date drift).
- "Different" replaces today's "Changed" bucket.
- Summary line: `X missing, Y different, Z present`, with an "all present" state when both missing and different are empty (tags may still need sync).

## Finder tags (`src/lib/tags.ts`, new)

- For each **Present** pair, read Finder tags on both sides via the `com.apple.metadata:_kMDItemUserTags` extended attribute using the `xattr` CLI, spawned in batches (works on SMB/NAS volumes where Spotlight/`mdls` does not).
- Pairs where the source has tags the target lacks go into a third bucket: **Tags**.
- Merge semantics = **union**: source tags are added to the target file; target-only tags are kept. Tags are never removed.
- Writing uses `xattr -w` with an XML plist payload (built with the existing `plist` dependency) — macOS property-list readers auto-detect XML vs binary, verified on this machine. Reading must decode both binary plists (Finder-written) and XML plists (written by us).
- Non-macOS: the tag step is skipped silently.

## Sync action

One "Sync" button (as today):

1. Copies **Missing** files preserving source-relative structure.
2. Copies **Different** files to their own source-relative path — never to `destRelPath`. `destRelPath` is display-only info about where the same-name candidate that caused the "different" verdict lives; a same-name file matched elsewhere in target is never overwritten, since two differently-sized source files sharing a name (e.g. `A/a.jpg` and `B/a.jpg`) would otherwise flip that one target file back and forth across syncs and never converge.
3. Applies tag merges for the **Tags** bucket (present pairs), plus source tags for files just copied under steps 1–2, since `fs.copyFile` drops extended attributes — otherwise a tagged missing/different file arrives untagged and needs a second sync pass.

Cancel and progress behavior unchanged.

## Error handling

- Tag read/write failures are collected and reported like copy errors; non-fatal.
- Scan errors surface in the status line as today.

## Out of scope

- Content hashing / checksum verification.
- mtime-based change detection (a possible future "deep scan" mode).
- Removing or reconciling tags beyond union merge.

## Files touched

- `src/lib/sync.ts` — matching rule changes.
- `src/lib/tags.ts` — new: batched tag read, tag write/merge.
- `src/main.ts` — sync-scan handler gains tag comparison; sync-transfer applies tag merges; exact-target plumbed through.
- `src/preload.ts` — API surface updates.
- `src/renderer.ts` + `index.html` — exact-folder target control, three-bucket results (Missing / Different / Tags), summary wording.

## Testing

Manual: sample source/target trees with nested-vs-flat structure, duplicate filenames with differing sizes, tagged files on both sides, and a target folder named differently from the source.
