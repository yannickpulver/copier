# Folder Sync Single Target Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Folder Sync tab's two destination controls (saved-destinations dropdown + "Exact folder…" override row) with one target row that accepts dropdown selection, drag & drop, and browse — with an inline "exact" toggle for name mismatches.

**Architecture:** A new pure module `src/lib/syncTarget.ts` holds the target-resolution rule (unit-tested). `src/renderer.ts` swaps the exact-row state (`syncExactDest`) for a per-target exact flag (`syncTargetExact`), makes the destination row a drop zone, supports transient (non-persisted) dropdown options, and renders a toggle link in the hint line when the chosen folder's name differs from the source's. Settings `syncTarget` + `syncTargetExact` replace `syncExactDest` (migrated on load).

**Tech Stack:** Electron, TypeScript, Vite, vitest. Paths are `/`-separated (macOS/Linux; matches existing `split('/')` usage in renderer).

**Spec:** `docs/superpowers/specs/2026-07-11-sync-single-target-design.md`

## Global Constraints

- Package manager is **pnpm** (`pnpm test`, `pnpm run lint`). Never npm/yarn.
- Do not push to main (push triggers the release workflow); do not run `pnpm start`.
- Renderer code cannot import `node:*` modules — pure lib modules only (pattern: `src/lib/dateFormat.ts`).
- The `+` browse button keeps today's behavior: it adds the picked folder to the shared saved `transferDests` list. Only **dropped** folders are transient (session-only, never written to `transferDests`).
- Selected-target resolution rule (from spec): exact flag → use path as-is; basename match with source → use as-is; otherwise append source basename.
- No Claude co-author lines in commits; commit messages describe the change only.

---

### Task 1: Pure target-resolution function

**Files:**
- Create: `src/lib/syncTarget.ts`
- Test: `src/lib/syncTarget.test.ts`

**Interfaces:**
- Produces: `resolveSyncTarget(sourcePath: string, targetPath: string, exact: boolean): string` — later tasks import this into the renderer. Returns `''` when `targetPath` is empty.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/syncTarget.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { resolveSyncTarget } from './syncTarget';

describe('resolveSyncTarget', () => {
  it('returns empty string when target is empty', () => {
    expect(resolveSyncTarget('/src/2024-trip', '', false)).toBe('');
    expect(resolveSyncTarget('/src/2024-trip', '', true)).toBe('');
  });

  it('returns target as-is when exact flag is set', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/SSD/2024-trip-final', true))
      .toBe('/Volumes/SSD/2024-trip-final');
  });

  it('returns target as-is when target basename matches source basename', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/SSD/Backup/2024-trip', false))
      .toBe('/Volumes/SSD/Backup/2024-trip');
  });

  it('appends source basename when names differ and exact is off', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/NAS/Photos', false))
      .toBe('/Volumes/NAS/Photos/2024-trip');
  });

  it('returns target as-is when source is empty', () => {
    expect(resolveSyncTarget('', '/Volumes/NAS/Photos', false)).toBe('/Volumes/NAS/Photos');
  });

  it('ignores trailing slashes when comparing basenames', () => {
    expect(resolveSyncTarget('/src/2024-trip/', '/Volumes/SSD/2024-trip/', false))
      .toBe('/Volumes/SSD/2024-trip/');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test -- syncTarget`
Expected: FAIL — cannot resolve `./syncTarget`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/syncTarget.ts` (no `node:*` imports — this is imported by the renderer):

```typescript
function basename(p: string): string {
  return p.replace(/\/+$/, '').split('/').pop() ?? '';
}

/**
 * Resolve the effective sync target.
 * - exact: use targetPath as-is
 * - target basename === source basename: use targetPath as-is
 * - otherwise: sync into <targetPath>/<source basename>
 */
export function resolveSyncTarget(sourcePath: string, targetPath: string, exact: boolean): string {
  if (!targetPath) return '';
  if (exact || !sourcePath) return targetPath;
  const srcName = basename(sourcePath);
  if (basename(targetPath) === srcName) return targetPath;
  return `${targetPath.replace(/\/+$/, '')}/${srcName}`;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test -- syncTarget`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/syncTarget.ts src/lib/syncTarget.test.ts
git commit -m "Add pure sync target resolution rule"
```

---

### Task 2: Settings keys

**Files:**
- Modify: `src/lib/store.ts:5-17` (AppSettings interface)

**Interfaces:**
- Produces: settings keys `syncTarget?: string` and `syncTargetExact?: boolean`, readable/writable via the existing `get-setting`/`set-setting` IPC (renderer calls `window.api.getSetting('syncTarget')` etc.). Legacy keys `syncSource`/`syncExactDest` already flow through IPC untyped (`key as any` in `main.ts:405-411`); add them to the interface too so the store is honest about what it holds.

- [ ] **Step 1: Add the keys**

In `src/lib/store.ts`, change the `AppSettings` interface:

```typescript
interface AppSettings {
  checkPaths?: { path: string; fallbackOnly?: boolean }[];
  transferDest?: string;
  transferDests?: string[];
  geminiKey?: string;
  synologyHost?: string;
  synologyPort?: number;
  synologyUser?: string;
  synologyPass?: string;
  synologySecure?: boolean;
  synologyFolders?: string;
  dateFormat?: string;
  syncSource?: string;
  syncExactDest?: string; // legacy — migrated to syncTarget/syncTargetExact on load
  syncTarget?: string;
  syncTargetExact?: boolean;
}
```

- [ ] **Step 2: Verify types compile**

Run: `pnpm exec tsc --noEmit`
Expected: exits 0 (same pre-existing errors as before the change, if any — compare with `git stash && pnpm exec tsc --noEmit` if unsure, then `git stash pop`).

- [ ] **Step 3: Commit**

```bash
git add src/lib/store.ts
git commit -m "Add syncTarget settings keys"
```

---

### Task 3: HTML — single target row with drop zone

**Files:**
- Modify: `index.html:292-305` (the Destination block inside `#sync-content`)

**Interfaces:**
- Produces element IDs consumed by Task 4: `#sync-dest-drop` (drop-zone row), `#sync-dest-select`, `#sync-browse-dest`, `#sync-dest-hint`. Removes `#sync-exact-drop`, `#sync-exact-btn`, `#sync-exact-label`, `#sync-exact-clear`.

- [ ] **Step 1: Replace the Destination block**

In `index.html`, replace lines 292–305 (the whole `<!-- Dest folder ... -->` block) with:

```html
        <!-- Target folder (dropdown + drag & drop + browse) -->
        <div class="space-y-1">
          <div class="text-[10px] uppercase tracking-wider text-neutral-500">Target</div>
          <div id="sync-dest-drop" class="flex items-center gap-2 border-2 border-dashed border-neutral-700 rounded-md px-2 py-1.5 transition-colors">
            <select id="sync-dest-select" class="flex-1 bg-neutral-800 border border-neutral-700 rounded px-2 py-1.5 text-xs focus:outline-none focus:border-blue-500"></select>
            <button id="sync-browse-dest" class="px-2 py-1 bg-neutral-700 hover:bg-neutral-600 rounded text-xs transition-colors shrink-0">+</button>
          </div>
          <div id="sync-dest-hint" class="text-[10px] text-neutral-500"></div>
        </div>
```

This mirrors the source row's drop-zone styling (`border-2 border-dashed border-neutral-700`, `dragover` swaps to `border-blue-500` in Task 4) and deletes the exact-folder row entirely.

- [ ] **Step 2: Verify no dangling references in HTML**

Run: `grep -n "sync-exact" index.html`
Expected: no output.

- [ ] **Step 3: Commit**

(The renderer still references the removed IDs at this point — it is committed together with Task 4 to keep the app working per commit. **Do not commit yet; proceed to Task 4.**)

---

### Task 4: Renderer — target state, transient options, exact toggle, migration

**Files:**
- Modify: `src/renderer.ts` — import block (line 4 area), and the Folder Sync section (`~1553-1700`)

**Interfaces:**
- Consumes: `resolveSyncTarget(sourcePath, targetPath, exact)` from Task 1; element IDs from Task 3; settings keys from Task 2.
- Produces: nothing consumed by later tasks (final wiring task).

- [ ] **Step 1: Import the resolver**

At the top of `src/renderer.ts`, extend the lib imports (below line 4):

```typescript
import { resolveSyncTarget } from './lib/syncTarget';
```

- [ ] **Step 2: Replace the exact-dest state and handlers**

In the Folder Sync section, **delete** all of the following (currently `renderer.ts:1573-1610`):

- `let syncExactDest = '';`
- the four element consts `syncExactBtn`, `syncExactLabel`, `syncExactClear`, `syncExactDrop`
- `function setSyncExactDest(...)`
- the `syncExactDrop` dragover/dragleave/drop listeners
- the `syncExactBtn` click listener
- the `syncExactClear` click listener

**Replace** with:

```typescript
let syncTargetExact = false;
const syncDestDrop = document.getElementById('sync-dest-drop')!;
const TRANSIENT_OPT_CLASS = 'sync-transient-opt';

function currentSyncTarget(): string {
  return syncDestSelect.value;
}

function persistSyncTarget() {
  window.api.setSetting('syncTarget', currentSyncTarget());
  window.api.setSetting('syncTargetExact', syncTargetExact);
}

/** Select a target path, adding it as a transient (non-persisted) option if it isn't a saved destination. */
function setSyncTarget(p: string, exact: boolean) {
  if (!transferDests.includes(p)) {
    syncDestSelect.querySelector(`.${TRANSIENT_OPT_CLASS}`)?.remove();
    const opt = document.createElement('option');
    opt.value = p;
    opt.textContent = p.split('/').pop() ?? p;
    opt.className = TRANSIENT_OPT_CLASS;
    syncDestSelect.appendChild(opt);
  }
  syncDestSelect.value = p;
  syncTargetExact = exact;
  persistSyncTarget();
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
  resetSyncResults();
}
```

- [ ] **Step 3: Rewrite `syncEffectiveDest` to use the resolver**

Replace the existing `syncEffectiveDest` function (`renderer.ts:1612-1621`) with:

```typescript
function syncEffectiveDest(): string {
  return resolveSyncTarget(syncSource, currentSyncTarget(), syncTargetExact);
}
```

- [ ] **Step 4: Rewrite the hint with the inline exact toggle**

Replace `updateSyncDestHint` (`renderer.ts:1623-1635`) with:

```typescript
function updateSyncDestHint() {
  const hint = document.getElementById('sync-dest-hint')!;
  const transferHint = document.getElementById('sync-transfer-hint')!;
  const target = currentSyncTarget();
  const dest = syncEffectiveDest();
  if (!syncSource || !dest) {
    hint.textContent = '';
    transferHint.textContent = '';
    return;
  }
  const short = dest.split('/').slice(-2).join('/');
  const srcName = syncSource.replace(/\/+$/, '').split('/').pop() ?? '';
  const targetName = target.replace(/\/+$/, '').split('/').pop() ?? '';
  const namesDiffer = !!srcName && !!targetName && srcName !== targetName;
  if (!namesDiffer) {
    hint.textContent = `→ ${short}/`;
  } else {
    const linkLabel = syncTargetExact
      ? 'sync into subfolder instead'
      : `sync into ${targetName} directly`;
    hint.innerHTML = `→ ${escapeHtml(short)}/${syncTargetExact ? ' (exact)' : ''} · <button id="sync-exact-toggle" class="underline text-blue-400 hover:text-blue-300">${escapeHtml(linkLabel)}</button>`;
    document.getElementById('sync-exact-toggle')!.addEventListener('click', () => {
      syncTargetExact = !syncTargetExact;
      persistSyncTarget();
      updateSyncDestHint();
      resetSyncResults();
    });
  }
  transferHint.textContent = `Will sync to ${syncEffectiveDest()}`;
}
```

Note: `transferHint` must reflect the *current* resolution — hence the second `syncEffectiveDest()` call after any toggle.

- [ ] **Step 5: Make the target row a drop zone and update select/browse handlers**

Replace the `sync-browse-dest` click listener and `syncDestSelect` change listener (`renderer.ts:1683-1699`) with:

```typescript
// Drag & drop for target (transient — not added to saved destinations)
syncDestDrop.addEventListener('dragover', (e) => {
  e.preventDefault();
  syncDestDrop.classList.replace('border-neutral-700', 'border-blue-500');
});
syncDestDrop.addEventListener('dragleave', () => {
  syncDestDrop.classList.replace('border-blue-500', 'border-neutral-700');
});
syncDestDrop.addEventListener('drop', (e) => {
  e.preventDefault();
  syncDestDrop.classList.replace('border-blue-500', 'border-neutral-700');
  const file = e.dataTransfer?.files[0];
  if (file) setSyncTarget(window.api.getPathForFile(file), false);
});

// + button: add a saved destination (shared transferDests list), then select it
document.getElementById('sync-browse-dest')!.addEventListener('click', async () => {
  const p = await window.api.browseFolder(currentSyncTarget() || undefined);
  if (!p) return;
  if (!transferDests.includes(p)) {
    transferDests.push(p);
    window.api.setSetting('transferDests', transferDests);
    populateSyncDests();
    populateTransferDests();
  }
  setSyncTarget(p, false);
});

syncDestSelect.addEventListener('change', () => {
  syncTargetExact = false;
  persistSyncTarget();
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
  resetSyncResults();
});
```

- [ ] **Step 6: Restore + migrate in `loadSyncPaths`, preserve transient option in `populateSyncDests`**

Replace `populateSyncDests` and `loadSyncPaths` (`renderer.ts:1647-1661`) with:

```typescript
function populateSyncDests() {
  const prev = syncDestSelect.value;
  syncDestSelect.innerHTML = transferDests.length
    ? transferDests.map((d) => `<option value="${escapeHtml(d)}">${escapeHtml(d.split('/').pop() ?? d)}</option>`).join('')
    : '<option value="">No destinations — open Settings</option>';
  if (prev && !transferDests.includes(prev)) {
    setSyncTarget(prev, syncTargetExact);
    return;
  }
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
}

async function loadSyncPaths() {
  const src = await window.api.getSetting('syncSource');
  if (src) setSyncSource(src);
  populateSyncDests();
  const [target, exact, legacyExact] = await Promise.all([
    window.api.getSetting('syncTarget'),
    window.api.getSetting('syncTargetExact'),
    window.api.getSetting('syncExactDest'),
  ]);
  if (legacyExact && !target) {
    // one-time migration from the removed "Exact folder…" row
    setSyncTarget(legacyExact, true);
    window.api.setSetting('syncExactDest', undefined);
  } else if (target) {
    setSyncTarget(target, !!exact);
  }
}
```

Note: `setSyncTarget` calls `resetSyncResults()`, which is a no-op at startup (results already empty). `populateSyncDests` re-adding a transient `prev` covers the case where saved destinations reload while a transient target is selected.

- [ ] **Step 7: Typecheck, tests, lint**

Run: `pnpm exec tsc --noEmit`
Expected: no *new* errors (`syncExactDest`-related references must all be gone).
Run: `pnpm test`
Expected: PASS (31 tests: 25 existing + 6 from Task 1).
Run: `pnpm run lint`
Expected: no new errors beyond the 5 pre-existing ones (in `matcher.ts`, `synology.ts`, `transfer.ts`, `renderer.ts:3`).

- [ ] **Step 8: Commit (Tasks 3 + 4 together)**

```bash
git add index.html src/renderer.ts
git commit -m "Folder sync: single target row with drop zone and inline exact toggle"
```

---

### Task 5: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: Ask the user to run the app** (per project rules the agent must not run `pnpm start`) and verify:

1. Target row shows saved destinations in the dropdown; dropping any folder onto the row selects it without adding it to Settings' destination list.
2. Source `X`, target root `Photos` → hint reads `→ Photos/X/`, plus link "sync into Photos directly".
3. Clicking the link flips hint to `→ Photos/ (exact)` with link "sync into subfolder instead"; scan results reset.
4. Source `X`, dropped target `.../X` → hint reads `→ .../X/` with **no** link.
5. Restart the app → last target and exact flag restored (transient option re-created if not saved).
6. Users upgrading with an old "Exact folder…" value: that path appears selected with `(exact)` in the hint on first launch.
7. Compare + Sync still work end-to-end into the resolved target.

- [ ] **Step 2: If all checks pass, done.** Any failure: fix, re-run `pnpm test` and `pnpm run lint`, amend the Task 4 commit or add a fix commit.
