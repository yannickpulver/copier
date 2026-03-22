import * as fs from 'node:fs';
import * as path from 'node:path';
import type { FileInfo } from './types';

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
): Promise<string[]> {
  await fs.promises.mkdir(destFolder, { recursive: true });
  const errors: string[] = [];

  for (let i = 0; i < files.length; i++) {
    const f = files[i];
    try {
      const dest = resolveCollision(path.join(destFolder, f.name));
      await fs.promises.copyFile(f.fullPath, dest);
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
): Promise<string[]> {
  const errors: string[] = [];
  const grouped = new Map<string, FileInfo[]>();

  for (const f of files) {
    const date = f.captureDate
      ? new Date(f.captureDate).toISOString().slice(0, 10).replace(/-/g, '.')
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
    const folderName = topic ? `${date} - ${topic}` : date;
    const destFolder = path.join(basePath, folderName);
    await fs.promises.mkdir(destFolder, { recursive: true });

    for (const f of dateFiles) {
      try {
        const dest = resolveCollision(path.join(destFolder, f.name));
        await fs.promises.copyFile(f.fullPath, dest);
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
    const destFolder = path.join(basePath, camera);
    await fs.promises.mkdir(destFolder, { recursive: true });

    for (const f of cameraFiles) {
      try {
        const dest = resolveCollision(path.join(destFolder, f.name));
        await fs.promises.copyFile(f.fullPath, dest);
      } catch (e: any) {
        errors.push(`${f.name}: ${e.message}`);
      }
      done++;
      onProgress?.(done, files.length, f.name);
    }
  }

  return errors;
}
