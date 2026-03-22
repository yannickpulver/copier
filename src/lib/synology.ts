import https from 'node:https';
import http from 'node:http';
import type { SynologyConfig } from './types';

type NasIndex = Map<string, string[]>;

function makeKey(name: string, size: number): string {
  return `${name}|${size}`;
}

interface SynoResponse {
  success: boolean;
  data?: any;
  error?: { code: number };
}

export class SynologyClient {
  private sid = '';
  private baseUrl: string;
  private config: SynologyConfig;

  constructor(config: SynologyConfig) {
    this.config = config;
    const proto = config.secure ? 'https' : 'http';
    this.baseUrl = `${proto}://${config.host}:${config.port}`;
  }

  async login(): Promise<void> {
    const params = new URLSearchParams({
      api: 'SYNO.API.Auth',
      version: '6',
      method: 'login',
      account: this.config.user,
      passwd: this.config.password,
      session: 'FileStation',
      format: 'sid',
    });
    const resp = await this.request(`/webapi/auth.cgi?${params}`);
    if (!resp.success) {
      throw new Error(`Synology login failed: error ${resp.error?.code ?? 'unknown'}`);
    }
    this.sid = resp.data.sid;
  }

  async indexFiles(
    nasPaths: string[],
    targetKeys?: Set<string>,
    onProgress?: (count: number, folder: string) => void,
  ): Promise<NasIndex> {
    const index: NasIndex = new Map();
    const remaining = targetKeys ? new Set(targetKeys) : null;
    let scanned = 0;

    for (const nasPath of nasPaths) {
      const foldersToScan = [nasPath];

      while (foldersToScan.length > 0) {
        const folder = foldersToScan.pop()!;
        scanned++;

        if (onProgress && scanned % 5 === 0) {
          const folderName = folder.includes('/') ? folder.split('/').pop()! : folder;
          onProgress(scanned, folderName);
        }

        try {
          let offset = 0;
          const limit = 5000;
          const subdirs: string[] = [];

          while (true) {
            const params = new URLSearchParams({
              api: 'SYNO.FileStation.List',
              version: '2',
              method: 'list',
              folder_path: folder,
              additional: '["size"]',
              limit: String(limit),
              offset: String(offset),
              _sid: this.sid,
            });

            const resp = await this.request(`/webapi/entry.cgi?${params}`);
            if (!resp.success || !resp.data) break;

            const items = resp.data.files ?? [];
            if (!items.length) break;

            for (const item of items) {
              if (item.isdir) {
                subdirs.push(item.path);
              } else {
                const name: string = item.name;
                const size: number = item.additional?.size ?? 0;
                const key = makeKey(name, size);
                const existing = index.get(key);
                if (existing) {
                  existing.push(folder);
                } else {
                  index.set(key, [folder]);
                }
                if (remaining) remaining.delete(key);
              }
            }

            if (items.length < limit) break;
            offset += limit;
          }

          // Early exit
          if (remaining && remaining.size === 0) {
            if (onProgress) onProgress(scanned, 'done — all found');
            return index;
          }

          // Sort ascending — pop() takes from end, so newest (e.g. 2026.03.22) scanned first
          foldersToScan.push(...subdirs.sort());
        } catch (e) {
          console.warn(`Synology scan error in ${folder}:`, e);
        }
      }
    }

    if (onProgress) onProgress(scanned, 'done');
    return index;
  }

  private request(urlPath: string): Promise<SynoResponse> {
    return new Promise((resolve, reject) => {
      const url = new URL(urlPath, this.baseUrl);
      const mod = this.config.secure ? https : http;
      const options = { rejectUnauthorized: false };

      const req = mod.get(url, options as any, (res) => {
        let data = '';
        res.on('data', (chunk: string) => { data += chunk; });
        res.on('end', () => {
          try {
            resolve(JSON.parse(data));
          } catch {
            reject(new Error(`Invalid JSON response from ${urlPath}`));
          }
        });
      });
      req.on('error', reject);
      req.end();
    });
  }
}
