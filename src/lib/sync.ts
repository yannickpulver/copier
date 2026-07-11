import * as fs from 'node:fs';
import * as path from 'node:path';

export interface SyncFileInfo {
  relPath: string;
  fullPath: string;
  name: string;
  size: number;
  mtime: number; // ms since epoch
  destRelPath?: string; // set when dest file lives at a different path
}

export interface MatchedPair {
  src: SyncFileInfo;
  dest: SyncFileInfo;
}

export interface SyncDiff {
  missing: SyncFileInfo[];   // no file with same name anywhere in dest
  different: SyncFileInfo[]; // same name exists but no size match
  present: MatchedPair[];    // name+size match anywhere in dest
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
    const destPath = path.join(destRoot, f.destRelPath ?? f.relPath);
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
