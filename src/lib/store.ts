import * as fs from 'node:fs';
import * as path from 'node:path';
import { app, safeStorage } from 'electron';

interface AppSettings {
  checkPaths?: { path: string; fallbackOnly?: boolean }[];
  transferDest?: string;
  transferDests?: string[];
  geminiKey?: string;
  synologyHost?: string;
  synologyPort?: number;
  synologyUser?: string;
  synologyPass?: string;
  synologySecure?: boolean;
  synologyFolders?: string;
  dateFormat?: string;
  syncSource?: string;
  syncExactDest?: string; // legacy — migrated to syncAppendSourceName on load
  syncTarget?: string;
  syncTargetExact?: boolean; // legacy — migrated to syncAppendSourceName on load
  syncAppendSourceName?: boolean;
}

// Secrets are encrypted at rest via the OS keychain (safeStorage). Legacy
// plaintext values are still readable and get encrypted on next save.
const SECRET_KEYS = new Set<keyof AppSettings>(['synologyPass', 'geminiKey']);
const ENC_PREFIX = 'enc:';

function encryptSecret(value: string): string {
  if (!value || value.startsWith(ENC_PREFIX) || !safeStorage.isEncryptionAvailable()) return value;
  return ENC_PREFIX + safeStorage.encryptString(value).toString('base64');
}

function decryptSecret(value: string): string {
  if (!value.startsWith(ENC_PREFIX)) return value;
  try {
    return safeStorage.decryptString(Buffer.from(value.slice(ENC_PREFIX.length), 'base64'));
  } catch {
    return '';
  }
}

const storePath = path.join(app.getPath('userData'), 'settings.json');

let cache: AppSettings | null = null;

function read(): AppSettings {
  if (!cache) {
    try {
      cache = JSON.parse(fs.readFileSync(storePath, 'utf-8'));
    } catch {
      cache = {};
    }
  }
  return cache!;
}

function write(settings: AppSettings): void {
  const tmp = storePath + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2));
  fs.renameSync(tmp, storePath);
}

export function getSetting<K extends keyof AppSettings>(key: K): AppSettings[K] {
  const value = read()[key];
  if (SECRET_KEYS.has(key) && typeof value === 'string') {
    return decryptSecret(value) as AppSettings[K];
  }
  return value;
}

export function setSetting<K extends keyof AppSettings>(key: K, value: AppSettings[K]): void {
  const settings = read();
  if (SECRET_KEYS.has(key) && typeof value === 'string') {
    settings[key] = encryptSecret(value) as AppSettings[K];
  } else {
    settings[key] = value;
  }
  write(settings);
}
