import * as fs from 'node:fs';
import * as path from 'node:path';
import type { FileInfo } from './types';
import { formatFolderDate, DEFAULT_DATE_FORMAT } from './dateFormat';

async function preserveTimestamps(src: string, dest: string): Promise<void> {
  const stat = await fs.promises.stat(src);
  await fs.promises.utimes(dest, stat.atime, stat.mtime);
}

export interface SpaceShortfall {
  requiredBytes: number;
  freeBytes: number;
  destPath: string;
}

function existingAncestor(p: string): string {
  let cur = path.resolve(p);
  while (!fs.existsSync(cur)) {
    const parent = path.dirname(cur);
    if (parent === cur) return cur;
    cur = parent;
  }
  return cur;
}

/** Pre-flight: verify each destination volume has room for the bytes headed
 * there. Returns the first shortfall found, or null if everything fits. */
export async function checkDiskSpace(
  targets: { dest: string; files: FileInfo[] }[],
): Promise<SpaceShortfall | null> {
  const byVolume = new Map<number, { required: number; dest: string; ancestor: string }>();

  for (const t of targets) {
    const ancestor = existingAncestor(t.dest);
    const dev = (await fs.promises.stat(ancestor)).dev;
    const bytes = t.files.reduce((s, f) => s + (f.size || 0), 0);
    const existing = byVolume.get(dev);
    if (existing) existing.required += bytes;
    else byVolume.set(dev, { required: bytes, dest: t.dest, ancestor });
  }

  for (const v of byVolume.values()) {
    const stats = await fs.promises.statfs(v.ancestor);
    const free = stats.bavail * stats.bsize;
    if (v.required > free) {
      return { requiredBytes: v.required, freeBytes: free, destPath: v.dest };
    }
  }

  return null;
}

function resolveCollision(filePath: string): string {
  if (!fs.existsSync(filePath)) return filePath;

  const dir = path.dirname(filePath);
  const ext = path.extname(filePath);
  const base = path.basename(filePath, ext);

  let i = 1;
  while (true) {
    const candidate = path.join(dir, `${base}_${i}${ext}`);
    if (!fs.existsSync(candidate)) return candidate;
    i++;
  }
}

export async function copyFiles(
  files: FileInfo[],
  destFolder: string,
  onProgress?: (current: number, total: number, name: string) => void,
  signal?: AbortSignal,
): Promise<string[]> {
  await fs.promises.mkdir(destFolder, { recursive: true });
  const errors: string[] = [];

  for (let i = 0; i < files.length; i++) {
    if (signal?.aborted) break;
    const f = files[i];
    try {
      const dest = resolveCollision(path.join(destFolder, f.name));
      await fs.promises.copyFile(f.fullPath, dest);
      await preserveTimestamps(f.fullPath, dest);
    } catch (e: any) {
      errors.push(`${f.name}: ${e.message}`);
    }
    onProgress?.(i + 1, files.length, f.name);
  }

  return errors;
}

export async function copyFilesGroupedByDate(
  files: FileInfo[],
  basePath: string,
  topic: string,
  onProgress?: (current: number, total: number, name: string) => void,
  signal?: AbortSignal,
  dateFormat: string = DEFAULT_DATE_FORMAT,
): Promise<string[]> {
  const errors: string[] = [];
  const grouped = new Map<string, FileInfo[]>();

  for (const f of files) {
    const date = f.captureDate
      ? formatFolderDate(new Date(f.captureDate).toISOString().slice(0, 10), dateFormat)
      : 'unknown';
    const existing = grouped.get(date);
    if (existing) {
      existing.push(f);
    } else {
      grouped.set(date, [f]);
    }
  }

  let done = 0;
  for (const [date, dateFiles] of grouped) {
    if (signal?.aborted) break;
    const folderName = topic ? `${date} - ${topic}` : date;
    const destFolder = path.join(basePath, folderName);
    await fs.promises.mkdir(destFolder, { recursive: true });

    for (const f of dateFiles) {
      if (signal?.aborted) break;
      try {
        const dest = resolveCollision(path.join(destFolder, f.name));
        await fs.promises.copyFile(f.fullPath, dest);
      await preserveTimestamps(f.fullPath, dest);
      } catch (e: any) {
        errors.push(`${f.name}: ${e.message}`);
      }
      done++;
      onProgress?.(done, files.length, f.name);
    }
  }

  return errors;
}

export async function copyFilesGroupedByCamera(
  files: FileInfo[],
  basePath: string,
  onProgress?: (current: number, total: number, name: string) => void,
  signal?: AbortSignal,
): Promise<string[]> {
  const errors: string[] = [];
  const grouped = new Map<string, FileInfo[]>();

  for (const f of files) {
    const camera = f.camera ?? 'Unknown';
    const existing = grouped.get(camera);
    if (existing) {
      existing.push(f);
    } else {
      grouped.set(camera, [f]);
    }
  }

  let done = 0;
  for (const [camera, cameraFiles] of grouped) {
    if (signal?.aborted) break;
    const destFolder = path.join(basePath, camera);
    await fs.promises.mkdir(destFolder, { recursive: true });

    for (const f of cameraFiles) {
      if (signal?.aborted) break;
      try {
        const dest = resolveCollision(path.join(destFolder, f.name));
        await fs.promises.copyFile(f.fullPath, dest);
      await preserveTimestamps(f.fullPath, dest);
      } catch (e: any) {
        errors.push(`${f.name}: ${e.message}`);
      }
      done++;
      onProgress?.(done, files.length, f.name);
    }
  }

  return errors;
}
