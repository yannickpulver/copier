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
const ISOBMFF_VIDEO_EXTS = new Set(['.mp4', '.mov', '.m4v', '.crm']);

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
  } else if (ISOBMFF_VIDEO_EXTS.has(ext)) {
    const video = await extractIsobmffMetadata(filePath);
    if (video) return video;
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

interface AtomLocation { dataStart: number; dataEnd: number }

async function findAtom(
  fh: fs.promises.FileHandle,
  type: string,
  start: number,
  end: number,
): Promise<AtomLocation | null> {
  const header = Buffer.alloc(16);
  let pos = start;
  while (pos + 8 <= end) {
    const { bytesRead } = await fh.read(header, 0, 16, pos);
    if (bytesRead < 8) return null;
    let size = header.readUInt32BE(0);
    const t = header.toString('latin1', 4, 8);
    let headerSize = 8;
    if (size === 1) {
      if (bytesRead < 16) return null;
      const hi = header.readUInt32BE(8);
      const lo = header.readUInt32BE(12);
      size = hi * 0x100000000 + lo;
      headerSize = 16;
    } else if (size === 0) {
      size = end - pos;
    }
    if (size < headerSize) return null;
    if (t === type) return { dataStart: pos + headerSize, dataEnd: pos + size };
    pos += size;
  }
  return null;
}

async function readRange(
  fh: fs.promises.FileHandle,
  start: number,
  end: number,
  cap = 4 * 1024 * 1024,
): Promise<Buffer> {
  const len = Math.min(end - start, cap);
  const buf = Buffer.alloc(len);
  const { bytesRead } = await fh.read(buf, 0, len, start);
  return buf.subarray(0, bytesRead);
}

async function extractIsobmffMetadata(filePath: string): Promise<MetadataResult | null> {
  let fh: fs.promises.FileHandle | undefined;
  try {
    fh = await fs.promises.open(filePath, 'r');
    const { size: fileSize } = await fh.stat();

    const moov = await findAtom(fh, 'moov', 0, fileSize);
    if (!moov) return null;

    // Try moov/meta (full box: 4-byte version+flags) and moov/udta/meta
    let metaStart: number | null = null;
    let metaEnd: number | null = null;
    const meta1 = await findAtom(fh, 'meta', moov.dataStart, moov.dataEnd);
    if (meta1) {
      metaStart = meta1.dataStart + 4;
      metaEnd = meta1.dataEnd;
    } else {
      const udta = await findAtom(fh, 'udta', moov.dataStart, moov.dataEnd);
      if (udta) {
        const meta2 = await findAtom(fh, 'meta', udta.dataStart, udta.dataEnd);
        if (meta2) {
          metaStart = meta2.dataStart + 4;
          metaEnd = meta2.dataEnd;
        }
      }
    }
    if (metaStart === null || metaEnd === null) return null;

    const keys = await findAtom(fh, 'keys', metaStart, metaEnd);
    const ilst = await findAtom(fh, 'ilst', metaStart, metaEnd);
    if (!ilst) return null;

    const keyList: string[] = [];
    if (keys) {
      const buf = await readRange(fh, keys.dataStart + 4, keys.dataEnd);
      const count = buf.readUInt32BE(0);
      let off = 4;
      for (let i = 0; i < count && off + 8 <= buf.length; i++) {
        const size = buf.readUInt32BE(off);
        if (size < 8 || off + size > buf.length) break;
        keyList.push(buf.toString('utf8', off + 8, off + size));
        off += size;
      }
    }

    const ilstBuf = await readRange(fh, ilst.dataStart, ilst.dataEnd);
    let model: string | undefined;
    let dateStr: string | undefined;
    let off = 0;
    while (off + 8 <= ilstBuf.length) {
      const size = ilstBuf.readUInt32BE(off);
      if (size < 8 || off + size > ilstBuf.length) break;
      const idx = ilstBuf.readUInt32BE(off + 4);
      const typeAscii = ilstBuf.toString('latin1', off + 4, off + 8);
      const key = keyList[idx - 1] ?? typeAscii;

      if (off + 16 <= off + size) {
        const dataSize = ilstBuf.readUInt32BE(off + 8);
        const dataType = ilstBuf.toString('latin1', off + 12, off + 16);
        if (dataType === 'data' && dataSize >= 16 && off + 8 + dataSize <= off + size) {
          const payload = ilstBuf
            .toString('utf8', off + 24, off + 8 + dataSize)
            .replace(/\0+$/, '')
            .trim();
          if (/(^|\.)model$/i.test(key) || key === '©mod') {
            model = payload;
          } else if (/(creationdate|date$)/i.test(key) || key === '©day') {
            dateStr ??= payload;
          }
        }
      }
      off += size;
    }

    let captureDate: string | undefined;
    if (dateStr) {
      const d = new Date(dateStr);
      if (!isNaN(d.getTime())) captureDate = d.toISOString();
    }
    if (!model && !captureDate) return null;
    return { captureDate, camera: model };
  } catch {
    return null;
  } finally {
    await fh?.close();
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
