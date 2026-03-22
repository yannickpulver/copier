import * as fs from 'node:fs';
import * as path from 'node:path';
import { app } from 'electron';

interface AppSettings {
  checkPaths?: { path: string; fallbackOnly?: boolean }[];
  transferDest?: string;
  synologyHost?: string;
  synologyPort?: number;
  synologyUser?: string;
  synologyPass?: string;
  synologySecure?: boolean;
  synologyFolders?: string;
}

const storePath = path.join(app.getPath('userData'), 'settings.json');

function read(): AppSettings {
  try {
    return JSON.parse(fs.readFileSync(storePath, 'utf-8'));
  } catch {
    return {};
  }
}

function write(settings: AppSettings): void {
  fs.writeFileSync(storePath, JSON.stringify(settings, null, 2));
}

export function getSetting<K extends keyof AppSettings>(key: K): AppSettings[K] {
  return read()[key];
}

export function setSetting<K extends keyof AppSettings>(key: K, value: AppSettings[K]): void {
  const settings = read();
  settings[key] = value;
  write(settings);
}
