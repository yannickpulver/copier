# Folder Sync Target Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the basename-comparison magic in folder sync target resolution with an explicit "Append source folder name" checkbox (default checked).

**Architecture:** `resolveSyncTarget` (pure function in `src/lib/syncTarget.ts`) loses its name-matching logic and takes an explicit `append` flag. The renderer replaces the `syncTargetExact` state + inline toggle link with a persistent checkbox and a new `syncAppendSourceName` setting (migrated from `syncTargetExact` as `append = !exact`).

**Tech Stack:** Electron, TypeScript, vanilla DOM renderer, Tailwind classes in `index.html`, Vitest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-12-folder-sync-simplify-design.md`
- Checkbox default: **checked** (append on) for fresh installs.
- No basename-comparison guard — `target/name/name` is allowed and visible in the hint.
- Remove the `syncExactDest` legacy migration (dead code).
- Package manager: `pnpm`. Tests: `pnpm test` (vitest). Lint: `pnpm lint`.
- Commit messages: plain description, NO Co-Authored-By/Generated-by lines.
- Do NOT push to `main` (every push triggers a release).

---

### Task 1: Simplify `resolveSyncTarget`

**Files:**
- Modify: `src/lib/syncTarget.ts`
- Test: `src/lib/syncTarget.test.ts` (rewrite)

**Interfaces:**
- Consumes: nothing.
- Produces: `resolveSyncTarget(sourcePath: string, targetPath: string, append: boolean): string` — Task 2's renderer calls this with the checkbox state as `append`.

- [ ] **Step 1: Rewrite the test file with failing tests**

Replace the entire contents of `src/lib/syncTarget.test.ts` with:

```ts
import { describe, it, expect } from 'vitest';
import { resolveSyncTarget } from './syncTarget';

describe('resolveSyncTarget', () => {
  it('returns empty string when target is empty', () => {
    expect(resolveSyncTarget('/src/2024-trip', '', true)).toBe('');
    expect(resolveSyncTarget('/src/2024-trip', '', false)).toBe('');
  });

  it('returns target as-is when append is off', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/NAS/Photos', false))
      .toBe('/Volumes/NAS/Photos');
  });

  it('appends source basename when append is on', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/NAS/Photos', true))
      .toBe('/Volumes/NAS/Photos/2024-trip');
  });

  it('appends even when target basename matches source basename', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/SSD/2024-trip', true))
      .toBe('/Volumes/SSD/2024-trip/2024-trip');
  });

  it('strips trailing slashes before appending', () => {
    expect(resolveSyncTarget('/src/2024-trip/', '/Volumes/NAS/Photos/', true))
      .toBe('/Volumes/NAS/Photos/2024-trip');
  });

  it('returns target as-is when source is empty', () => {
    expect(resolveSyncTarget('', '/Volumes/NAS/Photos', true)).toBe('/Volumes/NAS/Photos');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test src/lib/syncTarget.test.ts`
Expected: FAIL — "appends even when target basename matches source basename" fails (old code returns `/Volumes/SSD/2024-trip`); the append-on cases fail because the third parameter currently means `exact` (inverted).

- [ ] **Step 3: Simplify the implementation**

Replace the entire contents of `src/lib/syncTarget.ts` with:

```ts
function basename(p: string): string {
  return p.replace(/\/+$/, '').split('/').pop() ?? '';
}

/**
 * Resolve the effective sync target.
 * - append: sync into <targetPath>/<source basename>
 * - otherwise: use targetPath as-is
 */
export function resolveSyncTarget(sourcePath: string, targetPath: string, append: boolean): string {
  if (!targetPath) return '';
  if (!append || !sourcePath) return targetPath;
  return `${targetPath.replace(/\/+$/, '')}/${basename(sourcePath)}`;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test src/lib/syncTarget.test.ts`
Expected: PASS (6 tests). Note: `pnpm test` runs the whole suite too — `src/lib/sync.test.ts` and `src/lib/tags.test.ts` must stay green (they don't import `resolveSyncTarget`, so no changes expected).

- [ ] **Step 5: Commit**

```bash
git add src/lib/syncTarget.ts src/lib/syncTarget.test.ts
git commit -m "Simplify resolveSyncTarget to explicit append flag"
```

---

### Task 2: Checkbox UI + settings migration in renderer

**Files:**
- Modify: `index.html` (sync target section, ~line 292-300)
- Modify: `src/renderer.ts` (folder sync section, ~line 1598-1779)

**Interfaces:**
- Consumes: `resolveSyncTarget(sourcePath, targetPath, append)` from Task 1.
- Produces: user-facing checkbox `#sync-append-checkbox`; setting key `syncAppendSourceName` (boolean). Old keys `syncTargetExact` and `syncExactDest` are cleared after migration.

- [ ] **Step 1: Add the checkbox to `index.html`**

In the "Target folder" block, insert the `<label>` between the `sync-dest-drop` div and the `sync-dest-hint` div:

```html
        <!-- Target folder (dropdown + drag & drop + browse) -->
        <div class="space-y-1">
          <div class="text-[10px] uppercase tracking-wider text-neutral-500">Target</div>
          <div id="sync-dest-drop" class="flex items-center gap-2 border-2 border-dashed border-neutral-700 rounded-md px-2 py-1.5 transition-colors">
            <select id="sync-dest-select" class="flex-1 bg-neutral-800 border border-neutral-700 rounded px-2 py-1.5 text-xs focus:outline-none focus:border-blue-500"></select>
            <button id="sync-browse-dest" class="px-2 py-1 bg-neutral-700 hover:bg-neutral-600 rounded text-xs transition-colors shrink-0">+</button>
          </div>
          <label class="flex items-center gap-1.5 text-[10px] text-neutral-400 cursor-pointer select-none">
            <input type="checkbox" id="sync-append-checkbox" checked class="accent-blue-500" />
            Append source folder name
          </label>
          <div id="sync-dest-hint" class="text-[10px] text-neutral-500"></div>
        </div>
```

- [ ] **Step 2: Replace `syncTargetExact` state with the checkbox in `src/renderer.ts`**

In the `// --- Folder Sync ---` section:

Replace:
```ts
let syncTargetExact = false;
const syncDestDrop = document.getElementById('sync-dest-drop')!;
```
with:
```ts
const syncAppendCheckbox = $<HTMLInputElement>('#sync-append-checkbox');
const syncDestDrop = document.getElementById('sync-dest-drop')!;
```

Replace `persistSyncTarget`:
```ts
function persistSyncTarget() {
  window.api.setSetting('syncTarget', currentSyncTarget());
  window.api.setSetting('syncAppendSourceName', syncAppendCheckbox.checked);
}
```

Replace `setSyncTarget` (drops the `exact` parameter):
```ts
/** Select a target path, adding it as a transient (non-persisted) option if it isn't a saved destination. */
function setSyncTarget(p: string) {
  if (!transferDests.includes(p)) {
    syncDestSelect.querySelector(`.${TRANSIENT_OPT_CLASS}`)?.remove();
    const opt = document.createElement('option');
    opt.value = p;
    opt.textContent = p.split('/').pop() ?? p;
    opt.className = TRANSIENT_OPT_CLASS;
    syncDestSelect.appendChild(opt);
  }
  syncDestSelect.value = p;
  persistSyncTarget();
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
  resetSyncResults();
}
```

Replace `syncEffectiveDest`:
```ts
function syncEffectiveDest(): string {
  return resolveSyncTarget(syncSource, currentSyncTarget(), syncAppendCheckbox.checked);
}
```

Replace `updateSyncDestHint` (removes the toggle link entirely):
```ts
function updateSyncDestHint() {
  const hint = document.getElementById('sync-dest-hint')!;
  const transferHint = document.getElementById('sync-transfer-hint')!;
  const dest = syncEffectiveDest();
  if (!syncSource || !dest) {
    hint.textContent = '';
    transferHint.textContent = '';
    return;
  }
  hint.textContent = `→ ${dest.split('/').slice(-2).join('/')}/`;
  transferHint.textContent = `Will sync to ${dest}`;
}
```

- [ ] **Step 3: Update call sites, add checkbox listener, rewrite `loadSyncPaths` migration**

In `populateSyncDests`, change `setSyncTarget(prev, syncTargetExact);` to `setSyncTarget(prev);`.

Replace `loadSyncPaths` (migrates `syncTargetExact` → `syncAppendSourceName`, deletes the `syncExactDest` dead code):
```ts
async function loadSyncPaths() {
  const src = await window.api.getSetting('syncSource');
  if (src) setSyncSource(src);
  populateSyncDests();
  const [target, append, legacyExact] = await Promise.all([
    window.api.getSetting('syncTarget'),
    window.api.getSetting('syncAppendSourceName'),
    window.api.getSetting('syncTargetExact'),
  ]);
  syncAppendCheckbox.checked =
    typeof append === 'boolean' ? append : typeof legacyExact === 'boolean' ? !legacyExact : true;
  if (typeof legacyExact === 'boolean') {
    window.api.setSetting('syncTargetExact', undefined);
    window.api.setSetting('syncAppendSourceName', syncAppendCheckbox.checked);
  }
  window.api.setSetting('syncExactDest', undefined);
  if (target) setSyncTarget(target);
}
```

In the target drop handler, change `if (file) setSyncTarget(window.api.getPathForFile(file), false);` to `if (file) setSyncTarget(window.api.getPathForFile(file));`.

In the `sync-browse-dest` click handler, change `setSyncTarget(p, false);` to `setSyncTarget(p);`.

Replace the `syncDestSelect` change listener (drops the `syncTargetExact = false;` reset):
```ts
syncDestSelect.addEventListener('change', () => {
  persistSyncTarget();
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
  resetSyncResults();
});
```

Add the checkbox listener directly after it:
```ts
syncAppendCheckbox.addEventListener('change', () => {
  persistSyncTarget();
  updateSyncDestHint();
  resetSyncResults();
});
```

- [ ] **Step 4: Verify no stale references and checks pass**

Run: `grep -n "syncTargetExact\|syncExactDest\|sync-exact-toggle" src/renderer.ts index.html`
Expected: only the two `loadSyncPaths` migration lines (`getSetting('syncTargetExact')`, `setSetting('syncTargetExact', undefined)`, `setSetting('syncExactDest', undefined)`) — no other hits, no hits in `index.html`.

Run: `pnpm test` — Expected: PASS (all suites).
Run: `pnpm lint` — Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add index.html src/renderer.ts
git commit -m "Replace folder sync exact-target magic with append-source-name checkbox"
```
