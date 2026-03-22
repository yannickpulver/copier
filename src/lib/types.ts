export interface SdCard {
  name: string;
  path: string;
}

export interface FileInfo {
  name: string;
  size: number;
  relPath: string;
  fullPath: string;
  captureDate?: string; // ISO string
  camera?: string;
  isMedia?: boolean;
}

export const MEDIA_EXTS = new Set([
  // Photos
  '.jpg', '.jpeg', '.heic', '.heif', '.png', '.tiff', '.tif',
  // Raw
  '.cr2', '.cr3', '.arw', '.nef', '.dng', '.raf', '.orf', '.rw2',
  // Video
  '.mp4', '.mov', '.avi', '.mts', '.m4v',
  // Sidecars
  '.xmp', '.aae',
]);

export interface ScanProgress {
  step: string;
  count: number;
  folder: string;
}

export interface SynologyConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  secure: boolean;
  folders: string[];
}

export interface TransferRequest {
  files: FileInfo[];
  dest: string;
  mode: 'new' | 'existing' | 'grouped';
  topic?: string;
}
