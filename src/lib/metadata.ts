import * as fs from 'node:fs';
import ExifReader from 'exifreader';
import type { FileInfo } from './types';

const EXIF_EXTS = new Set([
  '.jpg', '.jpeg', '.tif', '.tiff', '.dng',
  '.cr3', '.cr2', '.arw', '.nef', '.raf', '.orf', '.rw2',
  '.heic', '.heif', '.png',
]);

const RAW_EXTS = new Set([
  '.cr3', '.cr2', '.arw', '.nef', '.dng', '.raf', '.orf', '.rw2',
]);

const VIDEO_EXTS = new Set(['.mp4', '.mov', '.m4v', '.avi', '.mts', '.mxf', '.crm']);

interface MetadataResult {
  captureDate?: string;
  camera?: string;
}

export async function enrichMetadata(
  files: FileInfo[],
  onProgress?: (current: number, total: number) => void,
  signal?: AbortSignal,
): Promise<void> {
  for (let i = 0; i < files.length; i++) {
    if (signal?.aborted) throw new Error('aborted');
    if (!files[i].captureDate) {
      const meta = await extractMetadata(files[i].fullPath);
      files[i].captureDate = meta.captureDate;
      files[i].camera = meta.camera;
    }
    onProgress?.(i + 1, files.length);
  }
}

async function extractMetadata(filePath: string): Promise<MetadataResult> {
  const ext = filePath.slice(filePath.lastIndexOf('.')).toLowerCase();

  if (ext === '.raf') {
    const raf = await extractRafMetadata(filePath);
    if (raf) return raf;
  } else if (EXIF_EXTS.has(ext) || VIDEO_EXTS.has(ext)) {
    try {
      // RAW files (especially CR3/ISOBMFF) store EXIF beyond 128KB — read more for those
      const isRaw = RAW_EXTS.has(ext);
      const fh = await fs.promises.open(filePath, 'r');
      const readSize = isRaw ? 1024 * 1024 : 128 * 1024;
      const buffer = Buffer.alloc(readSize);
      const { bytesRead } = await fh.read(buffer, 0, readSize, 0);
      await fh.close();
      const tags = ExifReader.load(buffer.subarray(0, bytesRead), { expanded: true, excludeXmp: true });

      const dateStr =
        tags.exif?.DateTimeOriginal?.description ??
        tags.exif?.DateTime?.description;
      const camera = tags.exif?.Model?.description?.trim();

      let captureDate: string | undefined;
      if (dateStr) {
        const iso = dateStr.replace(/^(\d{4}):(\d{2}):(\d{2})/, '$1-$2-$3');
        captureDate = new Date(iso).toISOString();
      }

      return { captureDate, camera };
    } catch {
      // fall through
    }
  }

  // Fallback: file mtime
  try {
    const stat = await fs.promises.stat(filePath);
    return { captureDate: stat.mtime.toISOString() };
  } catch {
    return {};
  }
}

async function extractRafMetadata(filePath: string): Promise<MetadataResult | null> {
  // Fujifilm RAF: header at offset 84 has JPEG thumbnail offset/length;
  // the thumbnail's EXIF contains Model and capture date.
  let fh: fs.promises.FileHandle | undefined;
  try {
    fh = await fs.promises.open(filePath, 'r');
    const header = Buffer.alloc(96);
    await fh.read(header, 0, 96, 0);
    if (header.toString('ascii', 0, 15) !== 'FUJIFILMCCD-RAW') return null;
    const thumbOffset = header.readUInt32BE(84);
    const thumbLength = header.readUInt32BE(88);
    if (!thumbOffset || !thumbLength) return null;
    const readLen = Math.min(thumbLength, 1024 * 1024);
    const jpeg = Buffer.alloc(readLen);
    await fh.read(jpeg, 0, readLen, thumbOffset);
    const tags = ExifReader.load(jpeg, { expanded: true, excludeXmp: true });
    const dateStr =
      tags.exif?.DateTimeOriginal?.description ??
      tags.exif?.DateTime?.description;
    const camera = tags.exif?.Model?.description?.trim();
    let captureDate: string | undefined;
    if (dateStr) {
      const iso = dateStr.replace(/^(\d{4}):(\d{2}):(\d{2})/, '$1-$2-$3');
      captureDate = new Date(iso).toISOString();
    }
    return { captureDate, camera };
  } catch {
    return null;
  } finally {
    await fh?.close();
  }
}
