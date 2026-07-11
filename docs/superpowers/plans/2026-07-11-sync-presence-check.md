# Folder Sync Presence Check + Finder Tag Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Folder Sync tab answers "does every source file exist anywhere in the target?" via name+size matching (structure-independent), supports an exact-folder target override, and syncs macOS Finder tags from source to target.

**Architecture:** Electron app; pure diff/tag logic lives in `src/lib/` (main process), IPC handlers in `src/main.ts`, vanilla-TS UI in `src/renderer.ts` + `index.html`. `diffFolders` gets new bucket semantics (missing / different / present pairs); a new `src/lib/tags.ts` reads Finder tags recursively via `xattr -rpx` (2 spawns total, works on SMB/NAS), decodes binary/XML plists, and writes merged tags via `xattr -w` with an XML plist (macOS auto-detects plist format).

**Tech Stack:** TypeScript, Electron, Vite, vitest (new devDep), `plist` (existing dep), `bplist-parser` (new dep).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-sync-presence-check-design.md`.
- Package manager is **npm** (package-lock.json).
- Match rule: same **name + size** anywhere in target = present. Mtime is ignored entirely.
- Tag merge = union: source tags added to target, target-only tags kept, never removed. Tag identity = name part before `\n` (raw tags look like `"Red\n6"` or `"Holiday"`).
- Non-macOS: tag steps are skipped silently (`process.platform !== 'darwin'` → empty results).
- Tag xattr: `com.apple.metadata:_kMDItemUserTags`.
- Commits: plain descriptive messages, NO Co-Authored-By/Generated-by lines.
- Do not push to main (push triggers the release workflow); do not run `npm start`.
- Checks allowed freely: `npm test`, `npm run lint`.

### Verified `xattr -rpx` output format (real output from this Mac)

```
tagtest/sub/b.txt: 
3C 3F 78 6D 6C 20 76 65 72 73 69 6F 6E 3D 22 31 
2E 30 22 ... 
tagtest/a.txt: 
62 70 6C 69 73 74 30 30 ...
```

- Header line = `<path>: ` (path exactly as passed root + relative walk, colon, ONE trailing space, nothing else).
- Value lines = space-separated uppercase hex byte pairs, 16 per line, **trailing space**, no offsets, no ASCII column.
- Files without the attr print an error to **stderr** and the exit code is 1 — both must be ignored; stdout is still complete.
- Values may be **binary plists** (`bplist00…`, written by Finder) or **XML plists** (written by us) — decode must handle both.

---

### Task 1: Test infra + new `diffFolders` semantics, plumbed end-to-end

**Files:**
- Modify: `package.json` (add vitest devDep + `test` script)
- Create: `src/lib/sync.test.ts`
- Modify: `src/lib/sync.ts` (replace `SyncDiff`, `diffFolders`; add `MatchedPair`)
- Modify: `src/main.ts:504-533` (`sync-scan` handler result shape)
- Modify: `src/renderer.ts:39-50` (api types) and `src/renderer.ts:1677-1755` (scan handler + bucket rendering)

**Interfaces:**
- Consumes: existing `SyncFileInfo` (`src/lib/sync.ts:4-11`), `walkFolder`, `syncFiles` (unchanged).
- Produces (used by Tasks 3–5):
  - `interface MatchedPair { src: SyncFileInfo; dest: SyncFileInfo }`
  - `interface SyncDiff { missing: SyncFileInfo[]; different: SyncFileInfo[]; present: MatchedPair[] }`
  - `diffFolders(sourceFiles: SyncFileInfo[], destFiles: SyncFileInfo[]): SyncDiff`
  - IPC `sync-scan` returns `{ missing, different, presentCount: number, sourceTotal: number, destTotal: number }`
  - Renderer helper `renderSyncBucket(title: string, colorClass: string, files: any[]): string`

- [ ] **Step 1: Install vitest and add test script**

```bash
npm i -D vitest
```

In `package.json` `"scripts"`, after `"lint"`:

```json
"lint": "eslint --ext .ts,.tsx .",
"test": "vitest run"
```

- [ ] **Step 2: Write the failing tests**

Create `src/lib/sync.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { diffFolders, SyncFileInfo } from './sync';

const f = (relPath: string, size: number, mtime = 0): SyncFileInfo => ({
  relPath,
  fullPath: `/root/${relPath}`,
  name: relPath.split('/').pop()!,
  size,
  mtime,
});

describe('diffFolders', () => {
  it('reports file as missing when no file with that name exists in dest', () => {
    const diff = diffFolders([f('a.jpg', 100)], [f('b.jpg', 100)]);
    expect(diff.missing.map((x) => x.name)).toEqual(['a.jpg']);
    expect(diff.different).toEqual([]);
    expect(diff.present).toEqual([]);
  });

  it('reports file as present when name+size match in a different subfolder', () => {
    const src = f('sub/a.jpg', 100);
    const dest = f('other/deep/a.jpg', 100);
    const diff = diffFolders([src], [dest]);
    expect(diff.present).toEqual([{ src, dest }]);
    expect(diff.missing).toEqual([]);
    expect(diff.different).toEqual([]);
  });

  it('reports file as present when source is nested and dest is flat', () => {
    const diff = diffFolders([f('x/y/z/a.jpg', 5)], [f('a.jpg', 5)]);
    expect(diff.present).toHaveLength(1);
  });

  it('ignores mtime: same name+size with newer source mtime is present', () => {
    const diff = diffFolders([f('a.jpg', 100, 999999999)], [f('a.jpg', 100, 0)]);
    expect(diff.present).toHaveLength(1);
    expect(diff.different).toEqual([]);
  });

  it('reports different when name matches but no candidate has same size', () => {
    const diff = diffFolders([f('a.jpg', 100)], [f('sub/a.jpg', 200)]);
    expect(diff.different).toHaveLength(1);
    expect(diff.different[0].destRelPath).toBe('sub/a.jpg');
    expect(diff.missing).toEqual([]);
    expect(diff.present).toEqual([]);
  });

  it('different at identical relPath does not set destRelPath', () => {
    const diff = diffFolders([f('a.jpg', 100)], [f('a.jpg', 200)]);
    expect(diff.different[0].destRelPath).toBeUndefined();
  });

  it('prefers exact relPath match among several same-name same-size candidates', () => {
    const src = f('sub/a.jpg', 100);
    const other = f('elsewhere/a.jpg', 100);
    const exact = f('sub/a.jpg', 100);
    const diff = diffFolders([src], [other, exact]);
    expect(diff.present[0].dest).toBe(exact);
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL — `diff.missing`/`diff.present` undefined (current shape is `added`/`changed`/`unchanged`).

- [ ] **Step 4: Replace `SyncDiff` and `diffFolders` in `src/lib/sync.ts`**

Replace lines 13-17 (`SyncDiff`) and lines 59-98 (`diffFolders`) with:

```ts
export interface MatchedPair {
  src: SyncFileInfo;
  dest: SyncFileInfo;
}

export interface SyncDiff {
  missing: SyncFileInfo[];   // no file with same name anywhere in dest
  different: SyncFileInfo[]; // same name exists but no size match
  present: MatchedPair[];    // name+size match anywhere in dest
}
```

```ts
/** Compare source files against dest files by filename across any subfolder depth.
 *  Present = same name + same size anywhere in dest. Mtime is ignored. */
export function diffFolders(
  sourceFiles: SyncFileInfo[],
  destFiles: SyncFileInfo[],
): SyncDiff {
  // Index dest files by filename (multiple files can share a name)
  const destByName = new Map<string, SyncFileInfo[]>();
  for (const f of destFiles) {
    const list = destByName.get(f.name);
    if (list) list.push(f);
    else destByName.set(f.name, [f]);
  }

  const missing: SyncFileInfo[] = [];
  const different: SyncFileInfo[] = [];
  const present: MatchedPair[] = [];

  for (const src of sourceFiles) {
    const candidates = destByName.get(src.name);
    if (!candidates || candidates.length === 0) {
      missing.push(src);
      continue;
    }

    const sameSize = candidates.filter((d) => d.size === src.size);
    if (sameSize.length === 0) {
      const dest = candidates.find((d) => d.relPath === src.relPath) ?? candidates[0];
      different.push(dest.relPath !== src.relPath
        ? { ...src, destRelPath: dest.relPath }
        : src);
      continue;
    }

    const dest = sameSize.find((d) => d.relPath === src.relPath) ?? sameSize[0];
    present.push({ src, dest });
  }

  return { missing, different, present };
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test`
Expected: PASS (7 tests).

- [ ] **Step 6: Update `sync-scan` handler in `src/main.ts`**

Replace the `const diff = ...; return {...};` block (lines 525-532) with:

```ts
  const diff = diffFolders(sourceFiles, destFiles);
  return {
    missing: diff.missing,
    different: diff.different,
    presentCount: diff.present.length,
    sourceTotal: sourceFiles.length,
    destTotal: destFiles.length,
  };
```

- [ ] **Step 7: Update renderer api types**

In `src/renderer.ts`, replace the `syncScan` type (lines 40-46) with:

```ts
      syncScan: (sourcePath: string, destPath: string) => Promise<{
        missing: any[];
        different: any[];
        presentCount: number;
        sourceTotal: number;
        destTotal: number;
      }>;
```

- [ ] **Step 8: Rewrite scan-result rendering in `src/renderer.ts`**

Add this helper right before the `syncScanBtn.addEventListener` block (before line 1677):

```ts
function renderSyncBucket(title: string, colorClass: string, files: any[]): string {
  if (!files.length) return '';
  return `
    <details open class="border border-neutral-700 rounded-md overflow-hidden mt-1">
      <summary class="flex items-center gap-3 px-3 py-2 bg-neutral-800/50 hover:bg-neutral-800 cursor-pointer text-xs">
        <span class="font-medium ${colorClass}">${title}</span>
        <span class="text-neutral-500">${files.length} file${files.length > 1 ? 's' : ''}</span>
        <span class="text-neutral-500 ml-auto">${formatSize(files.reduce((s, f) => s + f.size, 0))}</span>
      </summary>
      <table class="w-full text-xs">
        <tbody class="divide-y divide-neutral-800">
          ${files.map((f) => `
            <tr class="hover:bg-neutral-800/50 cursor-pointer" data-path="${escapeHtml(f.fullPath)}">
              <td class="px-3 py-1.5 truncate max-w-xs">${escapeHtml(f.relPath)}</td>
              <td class="px-3 py-1.5 text-right text-neutral-400 w-20 whitespace-nowrap">${formatSize(f.size)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </details>
  `;
}

// Click-to-reveal for all sync result rows (bound once, not per scan)
syncDiffList.addEventListener('click', (e) => {
  const row = (e.target as HTMLElement).closest('tr');
  if (row?.dataset.path) window.api.revealFile(row.dataset.path);
});
```

Replace the entire `syncScanBtn.addEventListener('click', ...)` handler (lines 1677-1755) with:

```ts
syncScanBtn.addEventListener('click', async () => {
  if (!syncSource || !syncDestSelect.value) return;

  syncScanBtn.disabled = true;
  syncStatus.textContent = 'Scanning...';
  resetSyncResults();

  try {
    const result = await window.api.syncScan(syncSource, syncEffectiveDest());
    const allDiff = [...result.missing, ...result.different];
    syncFilesToTransfer = allDiff;

    syncStatus.textContent = `${result.sourceTotal} source, ${result.destTotal} target — ${result.missing.length} missing, ${result.different.length} different, ${result.presentCount} present`;

    if (allDiff.length === 0) {
      syncAllSynced.classList.remove('hidden');
    } else {
      syncResults.classList.remove('hidden');
      syncTransferSection.classList.remove('hidden');
      syncTransferBtn.textContent = `Sync ${allDiff.length} files`;
      syncDiffList.innerHTML =
        renderSyncBucket('Missing', 'text-red-400', result.missing) +
        renderSyncBucket('Different', 'text-yellow-400', result.different);
    }
  } catch (e: any) {
    syncStatus.textContent = `Error: ${e.message}`;
  } finally {
    syncScanBtn.disabled = false;
  }
});
```

Note: the old handler re-registered the `syncDiffList` click listener on every scan (listener leak) — the rewrite binds it once outside.

Also update the "all synced" copy in `index.html:313` to reflect presence semantics:

```html
          <span class="text-sm text-neutral-300">All source files are present in the target</span>
```

- [ ] **Step 9: Verify checks pass**

Run: `npm test` → PASS. Run: `npm run lint` → no new errors (pre-existing warnings OK).

- [ ] **Step 10: Commit**

```bash
git add package.json package-lock.json src/lib/sync.ts src/lib/sync.test.ts src/main.ts src/renderer.ts index.html
git commit -m "Folder sync: presence check by name+size across subfolders, drop mtime; add vitest"
```

---

### Task 2: `src/lib/tags.ts` — Finder tag read/decode/merge/write

**Files:**
- Modify: `package.json` (add `bplist-parser` dep, `@types/bplist-parser` devDep)
- Create: `src/lib/tags.ts`
- Test: `src/lib/tags.test.ts`

**Interfaces:**
- Consumes: `MatchedPair` from `./sync` (Task 1); `plist` package (already a dependency, used in `scanner.ts`).
- Produces (used by Task 3):
  - `parseXattrDump(stdout: string): Map<string, Buffer>`
  - `decodeTags(data: Buffer): string[]`
  - `tagName(tag: string): string`
  - `mergeTags(sourceTags: string[], targetTags: string[]): string[] | null` — merged list, or `null` if target already has all source tag names
  - `interface TagUpdate { destPath: string; relPath: string; tags: string[]; addedNames: string[] }`
  - `computeTagUpdates(pairs: MatchedPair[], srcTags: Map<string, string[]>, destTags: Map<string, string[]>): TagUpdate[]`
  - `readTagsRecursive(root: string): Promise<Map<string, string[]>>` — keys are absolute file paths (root passed in must be absolute)
  - `writeTags(filePath: string, tags: string[]): Promise<void>`

- [ ] **Step 1: Install deps**

```bash
npm i bplist-parser
npm i -D @types/bplist-parser
```

(If `@types/bplist-parser` does not exist on the registry, instead create `src/types/bplist-parser.d.ts` containing: `declare module 'bplist-parser' { export function parseBuffer(buf: Buffer): any[]; }`)

- [ ] **Step 2: Write the failing tests**

Create `src/lib/tags.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { parseXattrDump, decodeTags, tagName, mergeTags, computeTagUpdates } from './tags';
import { SyncFileInfo } from './sync';

// Real binary plist for ["Red\n6", "Holiday"] (generated with plutil -convert binary1)
const BPLIST_HEX =
  '62706c6973743030a20102555265640a3657486f6c69646179080b11000000000000010100000000000000030000000000000000' +
  '0000000000000019';

// XML plist for ["Blue\n4"] as written by xattr -w
const XML_PLIST = '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Blue\n4</string></array></plist>';

/** Format a buffer the way `xattr -rpx` prints values: 16 uppercase hex pairs per line, trailing space. */
function hexDump(buf: Buffer): string {
  const pairs = buf.toString('hex').toUpperCase().match(/.{2}/g)!;
  const lines: string[] = [];
  for (let i = 0; i < pairs.length; i += 16) {
    lines.push(pairs.slice(i, i + 16).join(' ') + ' ');
  }
  return lines.join('\n');
}

describe('parseXattrDump', () => {
  it('parses multiple file entries with hex values', () => {
    const bufA = Buffer.from(BPLIST_HEX, 'hex');
    const bufB = Buffer.from(XML_PLIST, 'utf8');
    const stdout = `/Volumes/NAS/photos/a.jpg: \n${hexDump(bufA)}\n/Volumes/NAS/photos/sub/b file.jpg: \n${hexDump(bufB)}\n`;
    const map = parseXattrDump(stdout);
    expect(map.size).toBe(2);
    expect(map.get('/Volumes/NAS/photos/a.jpg')!.equals(bufA)).toBe(true);
    expect(map.get('/Volumes/NAS/photos/sub/b file.jpg')!.equals(bufB)).toBe(true);
  });

  it('returns empty map for empty output', () => {
    expect(parseXattrDump('').size).toBe(0);
  });
});

describe('decodeTags', () => {
  it('decodes binary plists (Finder-written)', () => {
    expect(decodeTags(Buffer.from(BPLIST_HEX, 'hex'))).toEqual(['Red\n6', 'Holiday']);
  });

  it('decodes XML plists (written by this app)', () => {
    expect(decodeTags(Buffer.from(XML_PLIST, 'utf8'))).toEqual(['Blue\n4']);
  });
});

describe('tagName', () => {
  it('strips the color suffix', () => {
    expect(tagName('Red\n6')).toBe('Red');
    expect(tagName('Holiday')).toBe('Holiday');
  });
});

describe('mergeTags', () => {
  it('adds source tags missing from target, keeping target tags first', () => {
    expect(mergeTags(['Red\n6', 'Trip'], ['Blue\n4'])).toEqual(['Blue\n4', 'Red\n6', 'Trip']);
  });

  it('returns null when target already has all source tag names', () => {
    expect(mergeTags(['Red'], ['Red\n6', 'Other'])).toBeNull();
  });

  it('returns null when source has no tags', () => {
    expect(mergeTags([], ['Blue\n4'])).toBeNull();
  });

  it('matches by name ignoring color suffix', () => {
    expect(mergeTags(['Red\n6'], ['Red'])).toBeNull();
  });
});

describe('computeTagUpdates', () => {
  const file = (fullPath: string): SyncFileInfo => ({
    relPath: fullPath.split('/').pop()!,
    fullPath,
    name: fullPath.split('/').pop()!,
    size: 1,
    mtime: 0,
  });

  it('produces updates only for pairs where source has tags the target lacks', () => {
    const pairs = [
      { src: file('/src/a.jpg'), dest: file('/dst/a.jpg') }, // src tagged, dst untagged -> update
      { src: file('/src/b.jpg'), dest: file('/dst/b.jpg') }, // both tagged same -> no update
      { src: file('/src/c.jpg'), dest: file('/dst/c.jpg') }, // src untagged, dst tagged -> no update (keep dst tags)
    ];
    const srcTags = new Map([
      ['/src/a.jpg', ['Red\n6']],
      ['/src/b.jpg', ['Holiday']],
    ]);
    const destTags = new Map([
      ['/dst/b.jpg', ['Holiday']],
      ['/dst/c.jpg', ['Keep']],
    ]);
    const updates = computeTagUpdates(pairs, srcTags, destTags);
    expect(updates).toEqual([
      { destPath: '/dst/a.jpg', relPath: 'a.jpg', tags: ['Red\n6'], addedNames: ['Red'] },
    ]);
  });

  it('merges into existing target tags', () => {
    const pairs = [{ src: file('/src/a.jpg'), dest: file('/dst/a.jpg') }];
    const updates = computeTagUpdates(
      pairs,
      new Map([['/src/a.jpg', ['Red\n6', 'Trip']]]),
      new Map([['/dst/a.jpg', ['Trip', 'Own']]]),
    );
    expect(updates[0].tags).toEqual(['Trip', 'Own', 'Red\n6']);
    expect(updates[0].addedNames).toEqual(['Red']);
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL — `./tags` module not found.

- [ ] **Step 4: Implement `src/lib/tags.ts`**

```ts
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import plist from 'plist';
import bplist from 'bplist-parser';
import { MatchedPair } from './sync';

const execFileP = promisify(execFile);

export const TAG_XATTR = 'com.apple.metadata:_kMDItemUserTags';

export interface TagUpdate {
  destPath: string;
  relPath: string;      // source relPath, for display
  tags: string[];       // full merged tag list to write
  addedNames: string[]; // tag names being added, for display
}

const HEX_LINE = /^([0-9A-Fa-f]{2})( [0-9A-Fa-f]{2})*$/;

/** Parse `xattr -rpx <attr> <root>` stdout: `<path>: ` header lines followed by hex value lines. */
export function parseXattrDump(stdout: string): Map<string, Buffer> {
  const result = new Map<string, Buffer>();
  let current: string | null = null;
  let hex = '';
  const flush = () => {
    if (current && hex) result.set(current, Buffer.from(hex, 'hex'));
    current = null;
    hex = '';
  };
  for (const rawLine of stdout.split('\n')) {
    const line = rawLine.trimEnd();
    if (current && HEX_LINE.test(line)) {
      hex += line.replace(/ /g, '');
    } else if (line.endsWith(':')) {
      flush();
      current = line.slice(0, -1);
    }
  }
  flush();
  return result;
}

/** Decode a _kMDItemUserTags value: binary plist (Finder) or XML plist (written by us). */
export function decodeTags(data: Buffer): string[] {
  const parsed = data.subarray(0, 8).toString('latin1') === 'bplist00'
    ? bplist.parseBuffer(data)[0]
    : plist.parse(data.toString('utf8'));
  return Array.isArray(parsed) ? parsed.filter((t): t is string => typeof t === 'string') : [];
}

/** Tag identity is the name before the `\n<color>` suffix ("Red\n6" -> "Red"). */
export function tagName(tag: string): string {
  return tag.split('\n')[0];
}

/** Union merge: target tags first, then source tags whose name is new. Null = nothing to add. */
export function mergeTags(sourceTags: string[], targetTags: string[]): string[] | null {
  const existing = new Set(targetTags.map(tagName));
  const toAdd = sourceTags.filter((t) => !existing.has(tagName(t)));
  return toAdd.length ? [...targetTags, ...toAdd] : null;
}

export function computeTagUpdates(
  pairs: MatchedPair[],
  srcTags: Map<string, string[]>,
  destTags: Map<string, string[]>,
): TagUpdate[] {
  const updates: TagUpdate[] = [];
  for (const { src, dest } of pairs) {
    const source = srcTags.get(src.fullPath);
    if (!source || source.length === 0) continue;
    const target = destTags.get(dest.fullPath) ?? [];
    const merged = mergeTags(source, target);
    if (!merged) continue;
    const targetNames = new Set(target.map(tagName));
    updates.push({
      destPath: dest.fullPath,
      relPath: src.relPath,
      tags: merged,
      addedNames: source.map(tagName).filter((n) => !targetNames.has(n)),
    });
  }
  return updates;
}

/** Read Finder tags for every file under root (absolute path). Two spawns per scan total.
 *  Files without tags produce stderr noise and exit code 1 — both ignored. */
export async function readTagsRecursive(root: string): Promise<Map<string, string[]>> {
  if (process.platform !== 'darwin') return new Map();
  const stdout = await new Promise<string>((resolve) => {
    const child = spawn('xattr', ['-rpx', TAG_XATTR, root]);
    const chunks: Buffer[] = [];
    child.stdout.on('data', (c: Buffer) => chunks.push(c));
    child.on('close', () => resolve(Buffer.concat(chunks).toString('utf8')));
    child.on('error', () => resolve(''));
  });
  const map = new Map<string, string[]>();
  for (const [p, buf] of parseXattrDump(stdout)) {
    try {
      const tags = decodeTags(buf);
      if (tags.length) map.set(p, tags);
    } catch { /* unreadable plist — skip file */ }
  }
  return map;
}

/** Write the full tag list as an XML plist xattr (macOS reads XML and binary alike). */
export async function writeTags(filePath: string, tags: string[]): Promise<void> {
  if (process.platform !== 'darwin') return;
  const xml = plist.build(tags);
  await execFileP('xattr', ['-w', TAG_XATTR, xml, filePath]);
}
```

Note on `parseXattrDump` vs. real output: real header lines end with `": "` (trailing space) and hex lines have a trailing space — `trimEnd()` normalizes both, so headers end with `:` and hex lines match `HEX_LINE`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test`
Expected: PASS (Task 1's 7 + Task 2's 11 tests).

- [ ] **Step 6: Live smoke test against the real `xattr` binary (macOS)**

```bash
mkdir -p /tmp/tags-smoke/sub
echo hi > /tmp/tags-smoke/a.txt
echo hi > /tmp/tags-smoke/sub/b.txt
xattr -w com.apple.metadata:_kMDItemUserTags '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Red
6</string></array></plist>' /tmp/tags-smoke/a.txt
xattr -rpx com.apple.metadata:_kMDItemUserTags /tmp/tags-smoke 2>/dev/null
rm -rf /tmp/tags-smoke
```

Expected: output contains a `/tmp/tags-smoke/a.txt: ` header line followed by hex lines (starting `3C 3F 78 6D` = `<?xm`); `sub/b.txt` does not appear. This confirms the parser's input format assumptions against the real binary on this machine.

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json src/lib/tags.ts src/lib/tags.test.ts
git commit -m "Add Finder tag lib: recursive xattr read, plist decode, union merge, write"
```

---

### Task 3: Wire tag sync into scan + transfer (main, preload, renderer)

**Files:**
- Modify: `src/main.ts` (`sync-scan` lines 506-533, `sync-transfer` lines 537-551, imports line 13)
- Modify: `src/preload.ts:49-52`
- Modify: `src/renderer.ts` (api types, scan handler, transfer handler, progress listener)

**Interfaces:**
- Consumes: `diffFolders` `SyncDiff.present: MatchedPair[]` (Task 1); `readTagsRecursive`, `computeTagUpdates`, `writeTags`, `TagUpdate` (Task 2).
- Produces:
  - IPC `sync-scan` result gains `tagUpdates: TagUpdate[]`
  - IPC `sync-transfer` signature becomes `(files, destRoot, tagUpdates)`; progress events count files + tags in one `total`
  - `sync-progress` gains `step: 'tags'`

- [ ] **Step 1: Update `src/main.ts` imports and `sync-scan`**

Line 13 becomes:

```ts
import { walkFolder, diffFolders, syncFiles } from './lib/sync';
import { readTagsRecursive, computeTagUpdates, writeTags, TagUpdate } from './lib/tags';
```

In the `sync-scan` handler, replace the `const diff = ...; return {...};` block (from Task 1 Step 6) with:

```ts
  const diff = diffFolders(sourceFiles, destFiles);

  mainWindow?.webContents.send('sync-progress', { step: 'tags', count: diff.present.length, folder: 'Checking Finder tags...' });
  const [srcTags, destTags] = await Promise.all([
    readTagsRecursive(sourcePath),
    readTagsRecursive(destPath),
  ]);
  const tagUpdates = computeTagUpdates(diff.present, srcTags, destTags);

  return {
    missing: diff.missing,
    different: diff.different,
    tagUpdates,
    presentCount: diff.present.length,
    sourceTotal: sourceFiles.length,
    destTotal: destFiles.length,
  };
```

- [ ] **Step 2: Update `sync-transfer` in `src/main.ts`**

Replace the handler (lines 537-551) with:

```ts
ipcMain.handle('sync-transfer', async (_event, files: any[], destRoot: string, tagUpdates: TagUpdate[] = []) => {
  syncAbort = new AbortController();
  const { signal } = syncAbort;
  const sleepBlockId = powerSaveBlocker.start('prevent-app-suspension');
  const total = files.length + tagUpdates.length;

  try {
    const errors = await syncFiles(files, destRoot, (current, _total, name) => {
      mainWindow?.webContents.send('sync-transfer-progress', { current, total, name });
    }, signal);

    let done = files.length;
    for (const u of tagUpdates) {
      if (signal.aborted) break;
      try {
        await writeTags(u.destPath, u.tags);
      } catch (e: any) {
        errors.push(`tags ${u.relPath}: ${e.message}`);
      }
      done++;
      mainWindow?.webContents.send('sync-transfer-progress', { current: done, total, name: u.relPath });
    }

    return { errors, cancelled: signal.aborted };
  } finally {
    powerSaveBlocker.stop(sleepBlockId);
    syncAbort = null;
  }
});
```

- [ ] **Step 3: Update `src/preload.ts`**

Replace lines 51-52 with:

```ts
  syncTransfer: (files: any[], destRoot: string, tagUpdates: any[]) =>
    ipcRenderer.invoke('sync-transfer', files, destRoot, tagUpdates),
```

- [ ] **Step 4: Update `src/renderer.ts` api types**

`syncScan` return type gains `tagUpdates: any[]` (add after `different: any[];`). `syncTransfer` becomes:

```ts
      syncTransfer: (files: any[], destRoot: string, tagUpdates: any[]) => Promise<{ errors: string[]; cancelled: boolean }>;
```

- [ ] **Step 5: Renderer — hold tag updates, render Tags bucket, pass to transfer**

Next to `let syncFilesToTransfer: any[] = [];` (line 1569) add:

```ts
let syncTagUpdates: any[] = [];
```

In `resetSyncResults()` add `syncTagUpdates = [];` after `syncFilesToTransfer = [];`.

In the `onSyncProgress` listener, replace the status template with:

```ts
window.api.onSyncProgress(({ step, count, folder }) => {
  const label = step === 'source' ? 'Source' : step === 'dest' ? 'Target' : 'Tags';
  syncStatus.textContent = `${label}: ${count} files — ${folder}`;
});
```

Add a tag-bucket renderer next to `renderSyncBucket` (from Task 1):

```ts
function renderTagBucket(updates: any[]): string {
  if (!updates.length) return '';
  return `
    <details open class="border border-neutral-700 rounded-md overflow-hidden mt-1">
      <summary class="flex items-center gap-3 px-3 py-2 bg-neutral-800/50 hover:bg-neutral-800 cursor-pointer text-xs">
        <span class="font-medium text-blue-400">Tags</span>
        <span class="text-neutral-500">${updates.length} file${updates.length > 1 ? 's' : ''}</span>
      </summary>
      <table class="w-full text-xs">
        <tbody class="divide-y divide-neutral-800">
          ${updates.map((u) => `
            <tr class="hover:bg-neutral-800/50 cursor-pointer" data-path="${escapeHtml(u.destPath)}">
              <td class="px-3 py-1.5 truncate max-w-xs">${escapeHtml(u.relPath)}</td>
              <td class="px-3 py-1.5 text-right text-blue-300 whitespace-nowrap">${u.addedNames.map((n: string) => `+${escapeHtml(n)}`).join(' ')}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </details>
  `;
}
```

In the scan handler (Task 1 Step 8 version), replace the body after `syncFilesToTransfer = allDiff;` with:

```ts
    syncTagUpdates = result.tagUpdates;

    const tagNote = result.tagUpdates.length ? `, ${result.tagUpdates.length} tag updates` : '';
    syncStatus.textContent = `${result.sourceTotal} source, ${result.destTotal} target — ${result.missing.length} missing, ${result.different.length} different, ${result.presentCount} present${tagNote}`;

    if (allDiff.length === 0 && result.tagUpdates.length === 0) {
      syncAllSynced.classList.remove('hidden');
    } else {
      syncResults.classList.remove('hidden');
      syncTransferSection.classList.remove('hidden');
      const parts = [];
      if (allDiff.length) parts.push(`${allDiff.length} file${allDiff.length > 1 ? 's' : ''}`);
      if (result.tagUpdates.length) parts.push(`${result.tagUpdates.length} tag${result.tagUpdates.length > 1 ? 's' : ''}`);
      syncTransferBtn.textContent = `Sync ${parts.join(' · ')}`;
      syncDiffList.innerHTML =
        renderSyncBucket('Missing', 'text-red-400', result.missing) +
        renderSyncBucket('Different', 'text-yellow-400', result.different) +
        renderTagBucket(result.tagUpdates);
    }
```

In the `syncTransferBtn` click handler, replace the guard and invoke lines:

```ts
syncTransferBtn.addEventListener('click', async () => {
  if ((!syncFilesToTransfer.length && !syncTagUpdates.length) || !syncDestSelect.value) return;
```

and

```ts
    const result = await window.api.syncTransfer(syncFilesToTransfer, syncEffectiveDest(), syncTagUpdates);
```

- [ ] **Step 6: Verify checks**

Run: `npm test` → PASS. Run: `npm run lint` → no new errors.

- [ ] **Step 7: Commit**

```bash
git add src/main.ts src/preload.ts src/renderer.ts
git commit -m "Folder sync: detect and apply Finder tag updates for present files"
```

---

### Task 4: Exact-folder target override

**Files:**
- Modify: `index.html` (Destination block, lines 292-300)
- Modify: `src/renderer.ts` (`syncEffectiveDest`, hint, enable-logic, persistence, new controls)

**Interfaces:**
- Consumes: `browseFolder` IPC (existing), `getSetting`/`setSetting` (existing), `syncEffectiveDest()` (existing renderer fn).
- Produces: setting key `syncExactDest` (string, empty = unset). `syncEffectiveDest()` returns the exact path verbatim when set.

- [ ] **Step 1: Add controls to `index.html`**

After the `sync-dest-hint` div (line 299), inside the Destination block, add:

```html
          <div class="flex items-center gap-2">
            <button id="sync-exact-btn" class="px-2 py-1 bg-neutral-800 hover:bg-neutral-700 border border-neutral-700 rounded text-[10px] text-neutral-400 transition-colors shrink-0">Exact folder…</button>
            <span id="sync-exact-label" class="hidden flex-1 text-[10px] text-blue-400 truncate"></span>
            <button id="sync-exact-clear" class="hidden px-1.5 py-1 bg-neutral-800 hover:bg-neutral-700 rounded text-[10px] text-neutral-400 shrink-0">✕</button>
          </div>
```

- [ ] **Step 2: Renderer state + behavior**

In `src/renderer.ts`, after the `syncSource`/`syncFilesToTransfer` declarations add:

```ts
let syncExactDest = '';
const syncExactBtn = document.getElementById('sync-exact-btn')!;
const syncExactLabel = document.getElementById('sync-exact-label')!;
const syncExactClear = document.getElementById('sync-exact-clear')!;

function setSyncExactDest(p: string) {
  syncExactDest = p;
  window.api.setSetting('syncExactDest', p);
  syncExactLabel.textContent = p;
  syncExactLabel.classList.toggle('hidden', !p);
  syncExactClear.classList.toggle('hidden', !p);
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
  resetSyncResults();
}

syncExactBtn.addEventListener('click', async () => {
  const p = await window.api.browseFolder(syncExactDest || syncDestSelect.value || undefined);
  if (p) setSyncExactDest(p);
});

syncExactClear.addEventListener('click', () => setSyncExactDest(''));
```

Change `syncEffectiveDest()` to return the override first:

```ts
function syncEffectiveDest(): string {
  if (syncExactDest) return syncExactDest;
  const base = syncDestSelect.value;
  if (!base || !syncSource) return base;
  const folderName = syncSource.split('/').pop() ?? syncSource;
  const destFolderName = base.split('/').pop() ?? '';
  // If dest already ends with the source folder name, use it directly
  if (destFolderName === folderName) return base;
  return `${base}/${folderName}`;
}
```

Update `updateSyncDestHint()`:

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
  const short = dest.split('/').slice(-2).join('/');
  hint.textContent = syncExactDest ? `→ ${short}/ (exact)` : `→ ${short}/`;
  transferHint.textContent = `Will sync to ${dest}`;
}
```

Replace every scan/transfer enable check that uses `!syncDestSelect.value` with `!syncEffectiveDest()`:
- `setSyncSource` (line 1601): `syncScanBtn.disabled = !syncSource || !syncEffectiveDest();`
- `populateSyncDests` (line 1609): same expression
- `syncDestSelect` change listener (line 1651): the exact override is intentional, so picking a different dest clears it:

```ts
syncDestSelect.addEventListener('change', () => {
  setSyncExactDest('');
  syncScanBtn.disabled = !syncSource || !syncEffectiveDest();
  updateSyncDestHint();
  resetSyncResults();
});
```

(Note `setSyncExactDest('')` already refreshes hint/disabled state; keeping the explicit lines after it is harmless and clear.)
- scan click guard: `if (!syncSource || !syncEffectiveDest()) return;`
- transfer click guard (Task 3 version): `if ((!syncFilesToTransfer.length && !syncTagUpdates.length) || !syncEffectiveDest()) return;`

In `loadSyncPaths()` restore the persisted override:

```ts
async function loadSyncPaths() {
  const src = await window.api.getSetting('syncSource');
  if (src) setSyncSource(src);
  const exact = await window.api.getSetting('syncExactDest');
  if (exact) setSyncExactDest(exact);
  populateSyncDests();
}
```

And in `populateSyncDests()` keep the disabled expression as updated above (it must not re-clear the exact override).

- [ ] **Step 3: Verify checks**

Run: `npm test` → PASS. Run: `npm run lint` → no new errors.

- [ ] **Step 4: Commit**

```bash
git add index.html src/renderer.ts
git commit -m "Folder sync: exact target folder override for differently-named folders"
```

---

### Task 5: End-to-end verification + version bump

**Files:**
- Modify: `VERSION`, `package.json` (+ lockfile)

**Interfaces:**
- Consumes: everything above.
- Produces: v1.5.0 ready to release (release publishes on push to main — leave pushing to the user).

- [ ] **Step 1: Full check run**

```bash
npm test && npm run lint
```

Expected: all tests PASS, no new lint errors.

- [ ] **Step 2: Build fixture folders for manual verification**

```bash
FIX=/tmp/sync-fixture && rm -rf $FIX && mkdir -p $FIX/source/day1 $FIX/target/somewhere/else
echo AAAA > $FIX/source/day1/present.jpg   && echo AAAA > $FIX/target/somewhere/else/present.jpg
echo BBBB > $FIX/source/day1/missing.jpg
echo CCCC > $FIX/source/day1/different.jpg && echo CCCCCC > $FIX/target/different.jpg
echo DDDD > $FIX/source/tagged.jpg         && echo DDDD > $FIX/target/somewhere/tagged.jpg
xattr -w com.apple.metadata:_kMDItemUserTags '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Red
6</string></array></plist>' $FIX/source/tagged.jpg
```

- [ ] **Step 3: Manual app verification (user runs the app)**

In the Folder Sync tab:
1. Source = `/tmp/sync-fixture/source`, then **Exact folder…** = `/tmp/sync-fixture/target`. Hint shows `(exact)`.
2. Compare folders → expect: 1 missing (`day1/missing.jpg`), 1 different (`day1/different.jpg`), 2 present, 1 tag update (`tagged.jpg` +Red).
3. Sync → rescan runs automatically → expect "All source files are present in the target".
4. `xattr -p com.apple.metadata:_kMDItemUserTags /tmp/sync-fixture/target/somewhere/tagged.jpg` shows a plist containing `Red`.
5. Clear the exact override → dest select behavior unchanged from before (appends source folder name).
6. Cleanup: `rm -rf /tmp/sync-fixture`.

- [ ] **Step 4: Version bump (release goes out on push)**

```bash
echo "1.5.0" > VERSION
npm version 1.5.0 --no-git-tag-version --allow-same-version
git add VERSION package.json package-lock.json
git commit -m "v1.5.0: Folder sync presence check (name+size, any structure), exact target override, Finder tag sync"
```

Do NOT push — the user pushes when ready to release.
