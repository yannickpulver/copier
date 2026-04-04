import * as fs from 'node:fs';
import * as path from 'node:path';

export interface SyncFileInfo {
  relPath: string;
  fullPath: string;
  name: string;
  size: number;
  mtime: number; // ms since epoch
}

export interface SyncDiff {
  added: SyncFileInfo[];   // in source but not in dest
  changed: SyncFileInfo[]; // in both but different size or newer mtime
  unchanged: number;
}

/** Recursively walk a directory and collect files. */
export async function walkFolder(
  root: string,
  onProgress?: (count: number, folder: string) => void,
): Promise<SyncFileInfo[]> {
  const results: SyncFileInfo[] = [];

  async function walk(dir: string) {
    let entries: fs.Dirent[];
    try {
      entries = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile()) {
        const stat = await fs.promises.stat(full);
        results.push({
          relPath: path.relative(root, full),
          fullPath: full,
          name: entry.name,
          size: stat.size,
          mtime: stat.mtimeMs,
        });
        if (onProgress && results.length % 100 === 0) {
          onProgress(results.length, path.relative(root, dir) || '.');
        }
      }
    }
  }

  await walk(root);
  onProgress?.(results.length, 'Done');
  return results;
}

/** Compare source files against dest files. */
export function diffFolders(
  sourceFiles: SyncFileInfo[],
  destFiles: SyncFileInfo[],
): SyncDiff {
  const destMap = new Map<string, SyncFileInfo>();
  for (const f of destFiles) {
    destMap.set(f.relPath, f);
  }

  const added: SyncFileInfo[] = [];
  const changed: SyncFileInfo[] = [];
  let unchanged = 0;

  for (const src of sourceFiles) {
    const dest = destMap.get(src.relPath);
    if (!dest) {
      added.push(src);
    } else if (src.size !== dest.size || src.mtime > dest.mtime + 1000) {
      // 1s tolerance for mtime (filesystem rounding)
      changed.push(src);
    } else {
      unchanged++;
    }
  }

  return { added, changed, unchanged };
}

/** Copy sync diff files from source to dest, preserving directory structure. */
export async function syncFiles(
  files: SyncFileInfo[],
  destRoot: string,
  onProgress?: (current: number, total: number, name: string) => void,
  signal?: AbortSignal,
): Promise<string[]> {
  const errors: string[] = [];

  for (let i = 0; i < files.length; i++) {
    if (signal?.aborted) break;
    const f = files[i];
    const destPath = path.join(destRoot, f.relPath);
    try {
      await fs.promises.mkdir(path.dirname(destPath), { recursive: true });
      await fs.promises.copyFile(f.fullPath, destPath);
      // Preserve timestamps
      const stat = await fs.promises.stat(f.fullPath);
      await fs.promises.utimes(destPath, stat.atime, stat.mtime);
    } catch (e: any) {
      errors.push(`${f.relPath}: ${e.message}`);
    }
    onProgress?.(i + 1, files.length, f.name);
  }

  return errors;
}
