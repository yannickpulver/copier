import { execFile } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import plist from 'plist';
import type { SdCard, FileInfo } from './types';
import { MEDIA_EXTS } from './types';

const HIDDEN_DIRS = new Set(['.Trashes', '.Spotlight-V100', '.fseventsd', '__MACOSX']);

export function listSdCards(): Promise<SdCard[]> {
  return new Promise((resolve) => {
    execFile('/usr/sbin/diskutil', ['list', '-plist'], { timeout: 10000 }, (err, stdout) => {
      if (err) { resolve([]); return; }

      try {
        const data = plist.parse(stdout) as any;
        const candidates: { ident: string; name: string; mount: string }[] = [];

        for (const disk of data.AllDisksAndPartitions ?? []) {
          const partitions = disk.Partitions?.length ? disk.Partitions : [disk];
          for (const part of partitions) {
            const mount = part.MountPoint ?? '';
            const ident = part.DeviceIdentifier ?? '';
            if (mount && mount !== '/' && fs.existsSync(mount)) {
              candidates.push({ ident, name: path.basename(mount), mount });
            }
          }
        }

        const checks = candidates.map((c) => checkVolume(c.ident, c.name, c.mount));
        Promise.all(checks).then((results) => {
          const cards = results.filter((r): r is SdCard => r !== null);
          resolve(cards);
        });
      } catch {
        resolve([]);
      }
    });
  });
}

function checkVolume(ident: string, name: string, mount: string): Promise<SdCard | null> {
  return new Promise((resolve) => {
    execFile('/usr/sbin/diskutil', ['info', '-plist', ident], { timeout: 5000 }, (err, stdout) => {
      if (err) { resolve(null); return; }
      try {
        const info = plist.parse(stdout) as any;
        const removable = info.RemovableMedia ?? false;
        const protocol = info.IORegistryEntryName ?? '';
        const isExternal = info.External ?? false;
        const isSsd = info.SolidState ?? false;
        const bus = info.BusProtocol ?? '';

        if (removable || isExternal || protocol.includes('Secure Digital') || bus === 'USB' || bus === 'Thunderbolt') {
          resolve({ name, path: mount });
        } else {
          resolve(null);
        }
      } catch {
        resolve(null);
      }
    });
  });
}

export async function scanFiles(
  volumePath: string,
  onProgress?: (count: number, folder: string) => void,
  signal?: AbortSignal,
): Promise<FileInfo[]> {
  const files: FileInfo[] = [];
  await walkDir(volumePath, volumePath, files, onProgress, signal);
  return files;
}

async function walkDir(
  root: string,
  dir: string,
  files: FileInfo[],
  onProgress?: (count: number, folder: string) => void,
  signal?: AbortSignal,
): Promise<void> {
  if (signal?.aborted) throw new Error('aborted');
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }

  const folderName = path.basename(dir);
  if (onProgress) onProgress(files.length, folderName);

  const subdirs: string[] = [];

  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;

    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      if (!HIDDEN_DIRS.has(entry.name)) {
        subdirs.push(full);
      }
    } else if (entry.isFile()) {
      try {
        const stat = await fs.promises.stat(full);
        const ext = path.extname(entry.name).toLowerCase();
        files.push({
          name: entry.name,
          size: stat.size,
          relPath: path.relative(root, full),
          fullPath: full,
          isMedia: MEDIA_EXTS.has(ext),
        });
      } catch {
        // skip unreadable
      }
    }
  }

  for (const sub of subdirs) {
    if (signal?.aborted) throw new Error('aborted');
    await walkDir(root, sub, files, onProgress, signal);
  }
}
