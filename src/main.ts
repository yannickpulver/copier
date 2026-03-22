import { app, BrowserWindow, ipcMain, dialog, shell } from 'electron';
import path from 'node:path';
import started from 'electron-squirrel-startup';

import { listSdCards, scanFiles } from './lib/scanner';
import { indexNas, checkBackedUp, listExistingFolders } from './lib/matcher';
import type { NasIndex, SourceIndex } from './lib/matcher';
import { SynologyClient } from './lib/synology';
import { loadSynologyConfig } from './lib/credentials';
import { enrichMetadata } from './lib/metadata';
import { copyFiles, copyFilesGroupedByDate } from './lib/transfer';
import type { SynologyConfig, FileInfo } from './lib/types';
import { getSetting, setSetting } from './lib/store';

if (started) app.quit();

let mainWindow: BrowserWindow;
let synologyConfig: SynologyConfig | null = null;

function sendProgress(step: string, count: number, folder: string) {
  mainWindow?.webContents.send('scan-progress', { step, count, folder });
}

const createWindow = () => {
  mainWindow = new BrowserWindow({
    width: 700,
    height: 600,
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  if (MAIN_WINDOW_VITE_DEV_SERVER_URL) {
    mainWindow.loadURL(MAIN_WINDOW_VITE_DEV_SERVER_URL);
  } else {
    mainWindow.loadFile(
      path.join(__dirname, `../renderer/${MAIN_WINDOW_VITE_NAME}/index.html`),
    );
  }
};

app.on('ready', createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });

// --- IPC Handlers ---

ipcMain.handle('list-sd-cards', async () => {
  return listSdCards();
});

ipcMain.handle('load-synology-config', async () => {
  synologyConfig = await loadSynologyConfig();
  if (synologyConfig) {
    return { available: true, folders: synologyConfig.folders };
  }
  return { available: false, folders: [] };
});

ipcMain.handle('scan', async (_event, sdPath: string) => {
  // 1. Scan SD
  sendProgress('sd', 0, 'Starting...');
  const sdFiles = await scanFiles(sdPath, (count, folder) => {
    sendProgress('sd', count, folder);
  });
  sendProgress('sd', sdFiles.length, 'Done');

  // 2. Build sources and scan all in parallel
  interface SourceResult { name: string; index: NasIndex; ok: boolean; error?: string }
  const sources: Promise<SourceResult>[] = [];

  // Synology API
  const synoConfig = await loadSynologyConfig();
  let apiOk = false;
  if (synoConfig) {
    sources.push((async (): Promise<SourceResult> => {
      try {
        sendProgress('source', 0, 'Synology API: connecting...');
        const client = new SynologyClient(synoConfig);
        await client.login();
        const targetKeys = new Set(sdFiles.map((f) => `${f.name}|${f.size}`));
        const index = await client.indexFiles(synoConfig.folders, targetKeys, (count, folder) => {
          sendProgress('source', count, `API: ${folder}`);
        });
        apiOk = true;
        return { name: 'Synology API', index, ok: true };
      } catch (e: any) {
        console.warn('Synology API failed:', e.message);
        return { name: 'Synology API', index: new Map(), ok: false, error: e.message };
      }
    })());
  }

  // Wait for API to finish first so we know if fallbacks are needed
  const apiResults = await Promise.all(sources);
  apiOk = apiResults.some((r) => r.ok && r.name === 'Synology API');
  sources.length = 0;

  // Local check paths
  const rawPaths = getSetting('checkPaths') ?? [];
  const checkPaths = rawPaths.map((item: any) =>
    typeof item === 'string' ? { path: item } : item
  );
  for (const cp of checkPaths) {
    if (cp.fallbackOnly && apiOk) {
      console.log(`Skipping fallback path: ${cp.path} (API succeeded)`);
      continue;
    }
    sources.push((async (): Promise<SourceResult> => {
      try {
        const label = cp.path.split('/').pop() ?? cp.path;
        sendProgress('source', 0, `${label}: scanning...`);
        const index = await indexNas(cp.path, (count, folder) => {
          sendProgress('source', count, `${label}: ${folder}`);
        });
        return { name: cp.path, index, ok: true };
      } catch (e: any) {
        return { name: cp.path, index: new Map(), ok: false, error: e.message };
      }
    })());
  }

  const localResults = await Promise.all(sources);
  const allResults = [...apiResults, ...localResults];

  if (allResults.length === 0) {
    throw new Error('No check sources configured. Open settings to add NAS or local paths.');
  }

  const results = allResults;
  const sourceIndexes: SourceIndex[] = results.map((r) => ({ name: r.name, index: r.index }));

  // 3. Match
  const { backedUp, missing, suggestedFolders } = checkBackedUp(sdFiles, sourceIndexes);

  // 4. Enrich dates for missing files only
  if (missing.length > 0) {
    sendProgress('dates', 0, 'Reading metadata...');
    await enrichMetadata(missing, (current, total) => {
      sendProgress('dates', current, `${current}/${total}`);
    });
  }

  return {
    total: sdFiles.length,
    backedUp: backedUp.length,
    missing,
    suggestedFolders,
    sources: results.map((r) => ({ name: r.name, ok: r.ok, error: r.error })),
  };
});

ipcMain.handle('list-existing-folders', (_event, nasPath: string) => {
  return listExistingFolders(nasPath);
});

ipcMain.handle('transfer', async (_event, files: FileInfo[], dest: string, mode: string, topic?: string, cameraSubfolder?: boolean) => {
  const onProgress = (current: number, total: number, name: string) => {
    mainWindow?.webContents.send('transfer-progress', { current, total, name });
  };

  if (cameraSubfolder) {
    // Group files by camera, then apply the chosen mode within each camera folder
    const byCamera = new Map<string, FileInfo[]>();
    for (const f of files) {
      const cam = f.camera ?? 'Unknown';
      const existing = byCamera.get(cam);
      if (existing) existing.push(f);
      else byCamera.set(cam, [f]);
    }
    const allErrors: string[] = [];
    let done = 0;
    for (const [camera, cameraFiles] of byCamera) {
      const cameraDest = path.join(dest, camera);
      let errors: string[];
      if (mode === 'grouped') {
        errors = await copyFilesGroupedByDate(cameraFiles, cameraDest, topic ?? '', (c, t, n) => {
          onProgress(done + c, files.length, n);
        });
      } else {
        errors = await copyFiles(cameraFiles, cameraDest, (c, t, n) => {
          onProgress(done + c, cameraFiles.length, n);
        });
      }
      done += cameraFiles.length;
      allErrors.push(...errors);
    }
    return allErrors;
  }

  if (mode === 'grouped') {
    return copyFilesGroupedByDate(files, dest, topic ?? '', onProgress);
  } else {
    return copyFiles(files, dest, onProgress);
  }
});

ipcMain.handle('get-setting', (_event, key: string) => {
  return getSetting(key as any);
});

ipcMain.handle('set-setting', (_event, key: string, value: any) => {
  setSetting(key as any, value);
});

ipcMain.on('reveal-file', (_event, filePath: string) => {
  shell.showItemInFolder(filePath);
});

ipcMain.handle('find-and-open-folder', async (_event, folderName: string, searchBase: string) => {
  const fs = await import('node:fs');
  const path = await import('node:path');

  // Try direct path first
  const direct = path.join(searchBase, folderName);
  if (fs.existsSync(direct)) {
    shell.openPath(direct);
    return true;
  }

  // Search one level of subdirs
  try {
    const entries = fs.readdirSync(searchBase, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const candidate = path.join(searchBase, entry.name, folderName);
      if (fs.existsSync(candidate)) {
        shell.openPath(candidate);
        return true;
      }
    }
  } catch { /* ignore */ }

  return false;
});

ipcMain.handle('browse-folder', async (_event, defaultPath?: string) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory'],
    defaultPath,
  });
  return result.canceled ? null : result.filePaths[0];
});
