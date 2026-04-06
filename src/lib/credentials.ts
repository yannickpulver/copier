import { execFile } from 'node:child_process';
import { getSetting } from './store';
import type { SynologyConfig } from './types';

export function resolveOpReference(value: string | undefined): Promise<string | undefined> {
  if (!value || !value.startsWith('op://')) return Promise.resolve(value);
  return new Promise((resolve) => {
    execFile('op', ['read', value], { timeout: 10000 }, (err, stdout) => {
      if (err) {
        console.warn(`Failed to resolve 1Password ref: ${err.message}`);
        resolve(undefined);
      } else {
        resolve(stdout.trim());
      }
    });
  });
}

export async function loadSynologyConfig(): Promise<SynologyConfig | null> {
  const rawHost = getSetting('synologyHost');
  const rawUser = getSetting('synologyUser');
  const rawPass = getSetting('synologyPass');
  if (!rawHost || !rawUser || !rawPass) return null;

  const [host, user, password] = await Promise.all([
    resolveOpReference(rawHost),
    resolveOpReference(rawUser),
    resolveOpReference(rawPass),
  ]);

  if (!host || !user || !password) return null;

  const rawFolders = getSetting('synologyFolders');
  const folders = Array.isArray(rawFolders)
    ? rawFolders
    : (typeof rawFolders === 'string' ? rawFolders.split(/\s+/).filter(Boolean) : []);
  if (!folders.length) return null;

  return {
    host,
    port: getSetting('synologyPort') ?? 5001,
    user,
    password,
    secure: getSetting('synologySecure') ?? true,
    folders,
  };
}
