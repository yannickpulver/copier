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
  resolveAmbiguousCameras(files);
}

// DJI multi-lens drones produce different model codes per lens.
// When an unambiguous drone-specific code is present alongside a shared
// wide-angle code (e.g., L2D-20c is shared by Mavic 3 / 3 Classic / 3 Pro),
// upgrade the ambiguous files to the specific drone seen in the batch.
function resolveAmbiguousCameras(files: FileInfo[]): void {
  const names = new Set(files.map((f) => f.camera).filter(Boolean) as string[]);
  const upgrades: Record<string, string> = {};
  if (names.has('DJI Mavic 3 Pro')) upgrades['DJI Mavic 3'] = 'DJI Mavic 3 Pro';
  if (Object.keys(upgrades).length === 0) return;
  for (const f of files) {
    if (f.camera && upgrades[f.camera]) f.camera = upgrades[f.camera];
  }
}

async function extractMetadata(filePath: string): Promise<MetadataResult> {
  const ext = filePath.slice(filePath.lastIndexOf('.')).toLowerCase();

  if (ext === '.raf') {
    const raf = await extractRafMetadata(filePath);
    if (raf) return await fillDateFromMtime(filePath, raf);
  } else if (ISOBMFF_VIDEO_EXTS.has(ext)) {
    const video = await extractIsobmffMetadata(filePath);
    if (video) return await fillDateFromMtime(filePath, video);
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
      const camera = cleanCameraName(tags.exif?.Model?.description);

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

async function fillDateFromMtime(filePath: string, result: MetadataResult): Promise<MetadataResult> {
  if (result.captureDate) return result;
  try {
    const stat = await fs.promises.stat(filePath);
    return { ...result, captureDate: stat.mtime.toISOString() };
  } catch {
    return result;
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
    const udta = await findAtom(fh, 'udta', moov.dataStart, moov.dataEnd);
    if (meta1) {
      metaStart = meta1.dataStart + 4;
      metaEnd = meta1.dataEnd;
    } else if (udta) {
      const meta2 = await findAtom(fh, 'meta', udta.dataStart, udta.dataEnd);
      if (meta2) {
        metaStart = meta2.dataStart + 4;
        metaEnd = meta2.dataEnd;
      }
    }
    if (metaStart === null || metaEnd === null) {
      if (udta) return await readClassicUdta(fh, udta);
      return null;
    }

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
    if (model || captureDate) return { captureDate, camera: cleanCameraName(model) };
    if (udta) return await readClassicUdta(fh, udta);
    return null;
  } catch {
    return null;
  } finally {
    await fh?.close();
  }
}

async function readClassicUdta(
  fh: fs.promises.FileHandle,
  udta: AtomLocation,
): Promise<MetadataResult | null> {
  const buf = await readRange(fh, udta.dataStart, udta.dataEnd);
  let model: string | undefined;
  let dateStr: string | undefined;
  let off = 0;
  while (off + 8 <= buf.length) {
    const size = buf.readUInt32BE(off);
    if (size < 8 || off + size > buf.length) break;
    const type = buf.toString('latin1', off + 4, off + 8);
    // Classic QT user-data atoms: ©mod, ©day, ©nam, ©xyz, etc.
    // Payload format: [2-byte text length][2-byte language code][text]
    if (type.charCodeAt(0) === 0xa9 && off + 12 <= off + size) {
      const textLen = buf.readUInt16BE(off + 8);
      const start = off + 12;
      if (textLen > 0 && start + textLen <= off + size) {
        const payload = buf.toString('utf8', start, start + textLen).replace(/\0+$/, '').trim();
        if (type === '©mod' || type === '©make') model ??= payload;
        else if (type === '©inf') {
          const cleaned = payload.replace(/^FUJIFILM\s+DIGITAL\s+CAMERA\s+/i, '').trim();
          if (cleaned && cleaned.toLowerCase() !== 'digital camera') model ??= cleaned;
        }
        else if (type === '©day') dateStr ??= payload;
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
  return { captureDate, camera: cleanCameraName(model) };
}

// Source: https://commons.wikimedia.org/wiki/DJI_camera_model_names
const DJI_MODEL_MAP: Record<string, string> = {
  // Phantom
  FC200: 'DJI Phantom 2 Vision',
  FC300C: 'DJI Phantom 3 Standard',
  FC300S: 'DJI Phantom 3 Advanced',
  FC300X: 'DJI Phantom 3 Professional',
  FC300XW: 'DJI Phantom 3 4K',
  FC300SE: 'DJI Phantom 3 SE',
  FC330: 'DJI Phantom 4',
  FC6310: 'DJI Phantom 4 Pro',
  FC6310S: 'DJI Phantom 4 Pro V2',
  FC6310R: 'DJI Phantom 4 RTK',
  FC6360: 'DJI P4 Multispectral',
  // Inspire
  FC350: 'DJI Inspire 1',
  FC550: 'DJI Inspire 1 Pro',
  FC550RAW: 'DJI Inspire 1 Pro',
  FC6510: 'DJI Inspire 2',
  FC6520: 'DJI Inspire 2',
  FC6540: 'DJI Inspire 2',
  FC4280: 'DJI Inspire 3',
  // Spark
  FC1102: 'DJI Spark',
  // Mavic
  FC220: 'DJI Mavic Pro',
  'L1D-20c': 'DJI Mavic 2 Pro',
  FC2220: 'DJI Mavic 2 Zoom',
  FC2204: 'DJI Mavic 2 Enterprise',
  FC2403: 'DJI Mavic 2 Enterprise Dual',
  'L2D-20c': 'DJI Mavic 3',
  FC4170: 'DJI Mavic 3',
  FC4382: 'DJI Mavic 3 Pro',
  FC4370: 'DJI Mavic 3 Pro',
  M3E: 'DJI Mavic 3E',
  M3M: 'DJI Mavic 3M',
  'L3D-100c': 'DJI Mavic 4 Pro',
  FC9284: 'DJI Mavic 4 Pro',
  FC9287: 'DJI Mavic 4 Pro',
  // Air
  FC230: 'DJI Mavic Air',
  FC2103: 'DJI Mavic Air 2',
  FC3170: 'DJI Mavic Air 2',
  FC3411: 'DJI Air 2S',
  FC8282: 'DJI Air 3',
  FC8284: 'DJI Air 3',
  FC9113: 'DJI Air 3S',
  FC9184: 'DJI Air 3S',
  // Mini
  FC7203: 'DJI Mini',
  FC7303: 'DJI Mini 2',
  FC7503: 'DJI Mini 2 SE',
  FC7703: 'DJI Mini 4K',
  FC3682: 'DJI Mini 3',
  FC3582: 'DJI Mini 3 Pro',
  FC8482: 'DJI Mini 4 Pro',
  FC9313: 'DJI Mini 5 Pro',
  // Avata / FPV / Flip
  FC8183: 'DJI Avata',
  FC8485: 'DJI Avata 2',
  OQ001E: 'DJI Avata 360',
  FC8582: 'DJI Flip',
  FC3305: 'DJI FPV',
  // Neo
  FC8671: 'DJI Neo',
  FC9470: 'DJI Neo 2',
  // Tello
  RZ001: 'Ryze Tello',
  // Osmo Action / Pocket
  AC002: 'DJI Osmo Action 3',
  AC003: 'DJI Osmo Action 4',
  AC004: 'DJI Osmo Action 5 Pro',
  'PP-101': 'DJI Osmo Pocket 3',
};

function cleanCameraName(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const first = raw.split(',')[0].trim();
  if (!first) return undefined;
  return DJI_MODEL_MAP[first] ?? first;
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
    const camera = cleanCameraName(tags.exif?.Model?.description);
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
