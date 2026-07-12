import * as fs from 'node:fs';
import * as path from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { FileInfo } from './types';
import { formatFolderDate, DEFAULT_DATE_FORMAT } from './dateFormat';

// Files are written to `<name>.copier-partial` and renamed into place only
// after the size is verified, so an interrupted transfer never leaves a
// truncated file under the real name (which would poison the dedupe index).
const PARTIAL_SUFFIX = '.copier-partial';
const COPY_CONCURRENCY = 3;
const STREAM_CHUNK = 4 * 1024 * 1024;

export interface CopyJob {
  file: FileInfo;
  destFolder: string;
}

export interface CopyProgress {
  current: number;
  total: number;
  name: string;
  bytesDone: number;
  bytesTotal: number;
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

function reserveName(names: Set<string>, name: string): string {
  if (!names.has(name)) {
    names.add(name);
    return name;
  }
  const ext = path.extname(name);
  const base = path.basename(name, ext);
  for (let i = 1; ; i++) {
    const candidate = `${base}_${i}${ext}`;
    if (!names.has(candidate)) {
      names.add(candidate);
      return candidate;
    }
  }
}

/** Stream-copy src to dest via a partial file: abortable mid-file, reports
 * byte deltas, verifies size, preserves timestamps, then renames into place. */
export async function copyOne(
  src: string,
  dest: string,
  onBytes?: (delta: number) => void,
  signal?: AbortSignal,
): Promise<void> {
  const tmp = dest + PARTIAL_SUFFIX;
  try {
    const read = fs.createReadStream(src, { highWaterMark: STREAM_CHUNK });
    if (onBytes) read.on('data', (chunk) => onBytes(chunk.length));
    await pipeline(read, fs.createWriteStream(tmp), { signal });
    const [srcStat, tmpStat] = await Promise.all([
      fs.promises.stat(src),
      fs.promises.stat(tmp),
    ]);
    if (tmpStat.size !== srcStat.size) {
      throw new Error(`size mismatch after copy (${tmpStat.size} of ${srcStat.size} bytes)`);
    }
    await fs.promises.utimes(tmp, srcStat.atime, srcStat.mtime);
    await fs.promises.rename(tmp, dest);
  } catch (e) {
    await fs.promises.unlink(tmp).catch(() => undefined);
    throw e;
  }
}

/** Copy a batch of files with bounded concurrency. Destination folders are
 * created and pre-listed once (collision resolution without per-file network
 * round trips); stale partial files from earlier interrupted runs are removed. */
export async function copyBatch(
  jobs: CopyJob[],
  onProgress?: (p: CopyProgress) => void,
  signal?: AbortSignal,
): Promise<string[]> {
  const errors: string[] = [];
  const total = jobs.length;
  const bytesTotal = jobs.reduce((s, j) => s + (j.file.size || 0), 0);

  const folders = new Map<string, Set<string>>();
  const failedFolders = new Set<string>();
  for (const j of jobs) {
    if (folders.has(j.destFolder) || failedFolders.has(j.destFolder)) continue;
    try {
      await fs.promises.mkdir(j.destFolder, { recursive: true });
      const names = new Set<string>();
      for (const name of await fs.promises.readdir(j.destFolder)) {
        if (name.endsWith(PARTIAL_SUFFIX)) {
          await fs.promises.unlink(path.join(j.destFolder, name)).catch(() => undefined);
        } else {
          names.add(name);
        }
      }
      folders.set(j.destFolder, names);
    } catch (e: any) {
      failedFolders.add(j.destFolder);
      errors.push(`${j.destFolder}: ${e.message}`);
    }
  }

  let bytesDone = 0;
  let done = 0;
  let next = 0;

  const worker = async () => {
    for (;;) {
      if (signal?.aborted) return;
      const idx = next++;
      if (idx >= jobs.length) return;
      const j = jobs[idx];
      const names = folders.get(j.destFolder);
      let copied = 0;
      if (!names) {
        errors.push(`${j.file.name}: destination folder unavailable`);
      } else {
        try {
          const dest = path.join(j.destFolder, reserveName(names, j.file.name));
          await copyOne(j.file.fullPath, dest, (delta) => {
            copied += delta;
            bytesDone += delta;
            onProgress?.({ current: done, total, name: j.file.name, bytesDone, bytesTotal });
          }, signal);
        } catch (e: any) {
          if (signal?.aborted) return;
          errors.push(`${j.file.name}: ${e.message}`);
          bytesDone += (j.file.size || 0) - copied;
        }
      }
      done++;
      onProgress?.({ current: done, total, name: j.file.name, bytesDone, bytesTotal });
    }
  };

  await Promise.all(
    Array.from({ length: Math.min(COPY_CONCURRENCY, jobs.length) }, worker),
  );
  return errors;
}

export function flatJobs(files: FileInfo[], destFolder: string): CopyJob[] {
  return files.map((file) => ({ file, destFolder }));
}

export function dateGroupedJobs(
  files: FileInfo[],
  basePath: string,
  topic: string,
  dateFormat: string = DEFAULT_DATE_FORMAT,
): CopyJob[] {
  const jobs: CopyJob[] = [];
  for (const f of files) {
    const date = f.captureDate
      ? formatFolderDate(new Date(f.captureDate).toISOString().slice(0, 10), dateFormat)
      : 'unknown';
    const folderName = topic ? `${date} - ${topic}` : date;
    jobs.push({ file: f, destFolder: path.join(basePath, folderName) });
  }
  return jobs;
}

export function groupByCamera(files: FileInfo[]): Map<string, FileInfo[]> {
  const grouped = new Map<string, FileInfo[]>();
  for (const f of files) {
    const camera = f.camera ?? 'Unknown';
    const existing = grouped.get(camera);
    if (existing) existing.push(f);
    else grouped.set(camera, [f]);
  }
  return grouped;
}
