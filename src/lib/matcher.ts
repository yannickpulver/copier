import * as fs from 'node:fs';
import * as path from 'node:path';
import type { FileInfo } from './types';

export type NasIndex = Map<string, string[]>;

// System / recycle-bin folders that should never be scanned or suggested.
// Synology's @eaDir thumbnail dirs in particular shadow original filenames
// and make SMB walks several times slower.
const IGNORED_FOLDERS = new Set(
  ['$RECYCLE.BIN', 'System Volume Information', '#recycle', '@eaDir', '.Trashes', 'found.000']
    .map((n) => n.toLowerCase()),
);

const STAT_CONCURRENCY = 16;

function makeKey(name: string, size: number): string {
  return `${name}|${size}`;
}

export async function indexNas(
  nasPath: string,
  onProgress?: (count: number, folder: string) => void,
  targetKeys?: Set<string>,
): Promise<NasIndex> {
  const index: NasIndex = new Map();
  const remaining = targetKeys ? new Set(targetKeys) : null;
  await walkNas(nasPath, index, remaining, onProgress);
  return index;
}

/** Returns true when all target keys have been found (caller can stop). */
async function walkNas(
  dir: string,
  index: NasIndex,
  remaining: Set<string> | null,
  onProgress?: (count: number, folder: string) => void,
): Promise<boolean> {
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return false;
  }

  if (onProgress) onProgress(index.size, path.basename(dir));

  const subdirs: string[] = [];
  const fileNames: string[] = [];

  for (const entry of entries) {
    if (entry.name.startsWith('.') || IGNORED_FOLDERS.has(entry.name.toLowerCase())) continue;
    if (entry.isDirectory()) {
      subdirs.push(path.join(dir, entry.name));
    } else if (entry.isFile()) {
      fileNames.push(entry.name);
    }
  }

  // Stat files with bounded concurrency — sequential stats over SMB are
  // one network round trip each and dominate scan time.
  let next = 0;
  const statWorker = async () => {
    while (next < fileNames.length) {
      const name = fileNames[next++];
      try {
        const stat = await fs.promises.stat(path.join(dir, name));
        const key = makeKey(name, stat.size);
        const existing = index.get(key);
        if (existing) existing.push(dir);
        else index.set(key, [dir]);
        remaining?.delete(key);
      } catch {
        // skip
      }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(STAT_CONCURRENCY, fileNames.length) }, statWorker),
  );

  if (remaining && remaining.size === 0) return true;

  // Sort descending so newest folders are scanned first
  subdirs.sort().reverse();
  for (const sub of subdirs) {
    if (await walkNas(sub, index, remaining, onProgress)) return true;
  }
  return false;
}

export interface SourceIndex {
  name: string;
  index: NasIndex;
}

export interface SuggestedFolder {
  folder: string;
  count: number;
  source: string;
  newestMtime: number; // newest mtime among the matched SD files (recency signal)
}

// Walk up to the nearest ancestor whose name starts with YYYY.MM.DD or YYYY-MM-DD
function toDateLevelFolder(folderPath: string): string {
  const parts = folderPath.split(path.sep);
  for (let i = parts.length - 1; i >= 0; i--) {
    if (/^\d{4}[.\-]\d{2}[.\-]\d{2}/.test(parts[i])) {
      return parts.slice(0, i + 1).join(path.sep);
    }
  }
  return folderPath;
}

export function checkBackedUp(
  sdFiles: FileInfo[],
  sourceIndexes: SourceIndex[],
): { backedUp: FileInfo[]; missing: FileInfo[]; suggestedFolders: SuggestedFolder[] } {
  const merged = mergeIndexes(...sourceIndexes.map((s) => s.index));
  const backedUp: FileInfo[] = [];
  const missing: FileInfo[] = [];
  // Track folder → { count, source, newestMtime }
  const folderInfo = new Map<string, { count: number; source: string; newestMtime: number }>();

  // Build folder→source lookup (also index normalized date-level paths)
  const folderToSource = new Map<string, string>();
  for (const si of sourceIndexes) {
    for (const [, paths] of si.index) {
      for (const p of paths) {
        if (!folderToSource.has(p)) folderToSource.set(p, si.name);
        const top = toDateLevelFolder(p);
        if (!folderToSource.has(top)) folderToSource.set(top, si.name);
      }
    }
  }

  for (const f of sdFiles) {
    const key = makeKey(f.name, f.size);
    const paths = merged.get(key);
    if (paths) {
      backedUp.push(f);
      for (const p of paths) {
        const top = toDateLevelFolder(p);
        const existing = folderInfo.get(top);
        if (existing) {
          existing.count++;
          existing.newestMtime = Math.max(existing.newestMtime, f.mtime ?? 0);
        } else {
          folderInfo.set(top, {
            count: 1,
            source: folderToSource.get(p) ?? folderToSource.get(top) ?? 'Unknown',
            newestMtime: f.mtime ?? 0,
          });
        }
      }
    } else {
      missing.push(f);
    }
  }

  const suggestedFolders = [...folderInfo.entries()]
    .map(([folder, { count, source, newestMtime }]) => ({ folder, count, source, newestMtime }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 10);

  return { backedUp, missing, suggestedFolders };
}

export function mergeIndexes(...indexes: NasIndex[]): NasIndex {
  const merged: NasIndex = new Map();
  for (const idx of indexes) {
    for (const [key, paths] of idx) {
      const existing = merged.get(key);
      if (existing) existing.push(...paths);
      else merged.set(key, [...paths]);
    }
  }
  return merged;
}

export function listExistingFolders(nasPath: string): string[] {
  try {
    const entries = fs.readdirSync(nasPath, { withFileTypes: true });
    return entries
      .filter((e) => e.isDirectory() && !e.name.startsWith('.') && !IGNORED_FOLDERS.has(e.name.toLowerCase()))
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}
