# Folder Sync: Single Target Field

**Date:** 2026-07-11
**Status:** Approved

## Problem

The Folder Sync tab has two destination controls:

1. A dropdown of saved destinations (`sync-dest-select`, shared `transferDests` list) — the app appends the source folder's name to the selection.
2. A separate "Exact folder…" override row (`sync-exact-drop`, `syncExactDest` setting) that replaces the dropdown value entirely.

Two fields for one concept ("where do files end up") is confusing, and the dropdown restricts selection to saved destinations while the exact row can point anywhere.

## Design

### One target row

Replace both controls with a single row:

- The existing dropdown of saved destinations stays, the **+ browse** button stays, and the **whole row becomes a drop zone** (same interaction pattern as the source row).
- A **dropped** folder becomes the selected value; if it isn't in the saved `transferDests` list, it appears as a **transient option** — selectable this session, never written to `transferDests`. The **+ browse** button keeps its existing role: it adds the picked folder to the saved `transferDests` list and selects it.
- The "Exact folder…" row, the `syncExactDest` setting, and its clear button are removed.

### Target resolution (smart rule)

Reuses the logic already in `syncEffectiveDest` (`renderer.ts:1612`):

- Chosen folder's name **equals** the source folder's name → sync exactly into it.
  e.g. source `…/2024-trip`, chosen `/Volumes/SSD/Backup/2024-trip` → target is that folder.
- Otherwise → sync into `<chosen>/<source-name>`.
  e.g. chosen `/Volumes/NAS/Photos` → target `Photos/2024-trip` (created if missing).

### Inline "exact" toggle for name mismatches

When the chosen folder's name differs from the source folder's name, the hint line offers both interpretations:

- Default: `→ 2024-trip-final/2024-trip/` with a clickable link "sync into 2024-trip-final directly".
- Clicking flips to exact mode: `→ 2024-trip-final/ (exact)` with link "sync into subfolder instead".
- The toggle only renders when the names differ; when they match there is no ambiguity and no link.

### Persistence

- Last-used target path and its exact-mode flag are remembered (new settings replace `syncExactDest`; e.g. `syncTarget: string` + `syncTargetExact: boolean`). Restored on app start, including a transient dropdown option if the path isn't in `transferDests`.
- Migration: if a legacy `syncExactDest` value exists, restore it as the selected transient target with exact mode on, then drop the old key.

### Out of scope

- The main transfer tab's destination dropdown is unchanged (`transferDests` list still shared and managed there / via the + button).
- No recent-targets history list.

## Error handling

- Changing the target (select, drop, browse, or toggling exact) resets scan results, as the dest-select change handler does today.
- Scan button stays disabled until both source and resolved target exist (existing behavior).

## Testing

- `syncEffectiveDest`-equivalent resolution logic is extracted or kept pure enough to unit-test: name match → exact, mismatch → append, exact flag → always exact.
- Manual check: drop non-saved folder → transient option selected, not persisted to `transferDests`; restart restores last target + exact flag.
