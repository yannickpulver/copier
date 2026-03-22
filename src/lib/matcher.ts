import * as fs from 'node:fs';
import * as path from 'node:path';
import type { FileInfo } from './types';

export type NasIndex = Map<string, string[]>;

function makeKey(name: string, size: number): string {
  return `${name}|${size}`;
}

export async function indexNas(
  nasPath: string,
  onProgress?: (count: number, folder: string) => void,
): Promise<NasIndex> {
  const index: NasIndex = new Map();
  await walkNas(nasPath, index, onProgress);
  return index;
}

async function walkNas(
  dir: string,
  index: NasIndex,
  onProgress?: (count: number, folder: string) => void,
): Promise<void> {
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }

  if (onProgress) onProgress(index.size, path.basename(dir));

  const subdirs: string[] = [];

  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      subdirs.push(full);
    } else if (entry.isFile()) {
      try {
        const stat = await fs.promises.stat(full);
        const key = makeKey(entry.name, stat.size);
        const existing = index.get(key);
        if (existing) {
          existing.push(dir);
        } else {
          index.set(key, [dir]);
        }
      } catch {
        // skip
      }
    }
  }

  // Sort descending so newest folders are scanned first
  subdirs.sort().reverse();
  for (const sub of subdirs) {
    await walkNas(sub, index, onProgress);
  }
}

export interface SourceIndex {
  name: string;
  index: NasIndex;
}

export interface SuggestedFolder {
  folder: string;
  count: number;
  source: string;
}

export function checkBackedUp(
  sdFiles: FileInfo[],
  sourceIndexes: SourceIndex[],
): { backedUp: FileInfo[]; missing: FileInfo[]; suggestedFolders: SuggestedFolder[] } {
  const merged = mergeIndexes(...sourceIndexes.map((s) => s.index));
  const backedUp: FileInfo[] = [];
  const missing: FileInfo[] = [];
  // Track folder → { count, source }
  const folderInfo = new Map<string, { count: number; source: string }>();

  // Build folder→source lookup
  const folderToSource = new Map<string, string>();
  for (const si of sourceIndexes) {
    for (const [, paths] of si.index) {
      for (const p of paths) {
        if (!folderToSource.has(p)) folderToSource.set(p, si.name);
      }
    }
  }

  for (const f of sdFiles) {
    const key = makeKey(f.name, f.size);
    const paths = merged.get(key);
    if (paths) {
      backedUp.push(f);
      for (const p of paths) {
        const existing = folderInfo.get(p);
        if (existing) {
          existing.count++;
        } else {
          folderInfo.set(p, { count: 1, source: folderToSource.get(p) ?? 'Unknown' });
        }
      }
    } else {
      missing.push(f);
    }
  }

  const suggestedFolders = [...folderInfo.entries()]
    .map(([folder, { count, source }]) => ({ folder, count, source }))
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
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}
