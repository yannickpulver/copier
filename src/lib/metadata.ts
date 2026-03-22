import * as fs from 'node:fs';
import ExifReader from 'exifreader';
import type { FileInfo } from './types';

const EXIF_EXTS = new Set([
  '.jpg', '.jpeg', '.tif', '.tiff', '.dng',
  '.cr3', '.cr2', '.arw', '.nef', '.raf', '.orf', '.rw2',
  '.heic', '.heif', '.png',
]);

const VIDEO_EXTS = new Set(['.mp4', '.mov', '.m4v', '.avi', '.mts']);

interface MetadataResult {
  captureDate?: string;
  camera?: string;
}

export async function enrichMetadata(
  files: FileInfo[],
  onProgress?: (current: number, total: number) => void,
): Promise<void> {
  for (let i = 0; i < files.length; i++) {
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

  if (EXIF_EXTS.has(ext) || VIDEO_EXTS.has(ext)) {
    try {
      // Read only first 128KB — enough for EXIF headers, avoids loading 20MB+ RAW files
      const fh = await fs.promises.open(filePath, 'r');
      const buffer = Buffer.alloc(128 * 1024);
      await fh.read(buffer, 0, buffer.length, 0);
      await fh.close();
      const tags = ExifReader.load(buffer, { expanded: true, excludeXmp: true });

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
