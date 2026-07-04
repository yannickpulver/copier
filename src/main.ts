import { app, BrowserWindow, ipcMain, dialog, shell, powerSaveBlocker, Notification } from 'electron';
import path from 'node:path';
import started from 'electron-squirrel-startup';
import { updateElectronApp } from 'update-electron-app';

import { listSdCards, scanFiles, ejectVolume, disambiguateDuplicateNames } from './lib/scanner';
import { indexNas, checkBackedUp, listExistingFolders } from './lib/matcher';
import type { NasIndex, SourceIndex } from './lib/matcher';
import { SynologyClient } from './lib/synology';
import { loadSynologyConfig, resolveOpReference } from './lib/credentials';
import { enrichMetadata } from './lib/metadata';
import { copyBatch, flatJobs, dateGroupedJobs, groupByCamera, checkDiskSpace } from './lib/transfer';
import type { CopyJob } from './lib/transfer';
import { walkFolder, diffFolders, syncFiles } from './lib/sync';
import type { SynologyConfig, FileInfo } from './lib/types';
import { getSetting, setSetting } from './lib/store';

if (started) app.quit();

updateElectronApp();

let mainWindow: BrowserWindow;
let synologyConfig: SynologyConfig | null = null;

function sendProgress(step: string, count: number, folder: string) {
  mainWindow?.webContents.send('scan-progress', { step, count, folder });
}

const createWindow = () => {
  mainWindow = new BrowserWindow({
    width: 700,
    height: 780,
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
  const cards = await listSdCards();
  // Dev convenience: expose a fake SD card backed by a local fixture so the
  // scan/transfer flow can be exercised without inserting real media.
  if (!app.isPackaged) {
    const fs = await import('node:fs');
    const testPath = process.env.COPIER_TEST_SD || path.join(process.cwd(), 'dev-fixtures', 'test-sd');
    if (fs.existsSync(testPath)) {
      cards.unshift({ name: 'Test SD (dev)', path: testPath });
    }
  }
  return cards;
});

ipcMain.handle('eject-sd-card', async (_event, mountPath: string) => {
  try {
    await ejectVolume(mountPath);
    return { ok: true };
  } catch (e: any) {
    return { ok: false, error: e?.message ?? String(e) };
  }
});

ipcMain.handle('test-synology', async (_event, host: string, port: number, user: string, pass: string, secure: boolean, folders: string) => {
  try {
    const [resolvedHost, resolvedUser, resolvedPass] = await Promise.all([
      resolveOpReference(host),
      resolveOpReference(user),
      resolveOpReference(pass),
    ]);
    if (!resolvedHost || !resolvedUser || !resolvedPass) {
      return { ok: false, error: 'Failed to resolve 1Password references' };
    }
    const config: SynologyConfig = { host: resolvedHost, port, user: resolvedUser, password: resolvedPass, secure, folders: folders.trim().split(/\s+/).filter(Boolean) };
    const client = new SynologyClient(config);
    await client.login();
    return { ok: true };
  } catch (e: any) {
    return { ok: false, error: e.message };
  }
});

ipcMain.handle('load-synology-config', async () => {
  synologyConfig = await loadSynologyConfig();
  if (synologyConfig) {
    return { available: true, folders: synologyConfig.folders };
  }
  return { available: false, folders: [] };
});

ipcMain.handle('check-sources-status', async () => {
  const fs = await import('node:fs');

  interface SourceEntry { name: string; type: string; checkPath?: string }
  const sources: SourceEntry[] = [];

  const config = await loadSynologyConfig();
  if (config) {
    sources.push({ name: 'Synology API', type: 'synology' });
  }
  const rawPaths = getSetting('checkPaths') ?? [];
  const checkPaths = rawPaths.map((item: any) =>
    typeof item === 'string' ? { path: item, fallbackOnly: false } : item
  );
  for (const cp of checkPaths) {
    const label = cp.path.split('/').pop() ?? cp.path;
    sources.push({ name: label, type: cp.fallbackOnly ? 'fallback' : 'local', checkPath: cp.path });
  }

  // Send list so renderer shows pills with loaders
  mainWindow?.webContents.send('sources-list', sources.map((s) => ({ name: s.name, type: s.type })));

  // Check each in parallel, emit per-source result
  await Promise.all(sources.map(async (s, i) => {
    let available = false;
    if (s.type === 'synology' && config) {
      try {
        const client = new SynologyClient(config);
        await client.login();
        available = true;
      } catch { /* offline */ }
    } else if (s.checkPath) {
      available = fs.existsSync(s.checkPath);
    }
    mainWindow?.webContents.send('source-status', { index: i, available });
  }));
});

// Reject as soon as the scan is cancelled, even if `p` is still pending
// (e.g. waiting on an unresponsive Synology login). The underlying work is
// left to settle/time out on its own; we just stop waiting for it.
function abortable<T>(p: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new Error('aborted'));
    const onAbort = () => reject(new Error('aborted'));
    signal.addEventListener('abort', onAbort, { once: true });
    p.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort));
  });
}

let scanAbort: AbortController | null = null;

ipcMain.handle('cancel-scan', () => {
  scanAbort?.abort();
});

ipcMain.handle('scan', async (_event, sdPath: string, skipCheck?: boolean, disabledSources?: string[]) => {
  scanAbort?.abort();
  scanAbort = new AbortController();
  const signal = scanAbort.signal;
  const disabled = new Set(disabledSources ?? []);

  try {
  // 1. Scan SD
  sendProgress('sd', 0, 'Starting...');
  const sdFiles = await scanFiles(sdPath, (count, folder) => {
    sendProgress('sd', count, folder);
  }, signal);
  if (signal.aborted) throw new Error('aborted');
  // Make same-name files from different subfolders (e.g. DJI panoramas) unique
  // so they match on rescan instead of re-copying every time.
  disambiguateDuplicateNames(sdFiles);
  sendProgress('sd', sdFiles.length, 'Done');

  // Skip backup check — treat all media as new
  if (skipCheck) {
    const media = sdFiles.filter((f) => f.isMedia !== false);
    if (media.length > 0) {
      sendProgress('dates', 0, 'Reading metadata...');
      await enrichMetadata(media, (current, total) => {
        sendProgress('dates', current, `${current}/${total}`);
      }, signal);
    }
    if (signal.aborted) throw new Error('aborted');
    return {
      total: sdFiles.length,
      backedUp: 0,
      missing: media,
      suggestedFolders: [],
      sources: [],
    };
  }

  // 2. Build sources and scan all in parallel
  interface SourceResult { name: string; index: NasIndex; ok: boolean; error?: string }
  const sources: Promise<SourceResult>[] = [];
  const targetKeys = new Set(sdFiles.map((f) => `${f.name}|${f.size}`));

  // Synology API
  const synoConfig = await loadSynologyConfig();
  let apiOk = false;
  if (synoConfig && !disabled.has('Synology API')) {
    sources.push((async (): Promise<SourceResult> => {
      try {
        sendProgress('source', 0, 'Synology API: connecting...');
        const client = new SynologyClient(synoConfig);
        await client.login(4000);
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
  const apiResults = await abortable(Promise.all(sources), signal);
  apiOk = apiResults.some((r) => r.ok && r.name === 'Synology API');
  sources.length = 0;

  // Local check paths
  const rawPaths = getSetting('checkPaths') ?? [];
  const checkPaths = rawPaths.map((item: any) =>
    typeof item === 'string' ? { path: item } : item
  );
  for (const cp of checkPaths) {
    const label = cp.path.split('/').pop() ?? cp.path;
    if (disabled.has(label)) {
      console.log(`Skipping disabled source: ${label}`);
      continue;
    }
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
        }, targetKeys);
        return { name: cp.path, index, ok: true };
      } catch (e: any) {
        return { name: cp.path, index: new Map(), ok: false, error: e.message };
      }
    })());
  }

  const localResults = await abortable(Promise.all(sources), signal);
  const allResults = [...apiResults, ...localResults];

  // Only an error if nothing is configured at all. If sources exist but were
  // all excluded (offline/disabled), proceed — every file is treated as new.
  if (!synoConfig && checkPaths.length === 0) {
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
    }, signal);
  }
  if (signal.aborted) throw new Error('aborted');

  return {
    total: sdFiles.length,
    backedUp: backedUp.length,
    backedUpFiles: backedUp,
    missing,
    suggestedFolders,
    sources: results.map((r) => ({ name: r.name, ok: r.ok, error: r.error })),
  };
  } catch (e: any) {
    if (e?.message === 'aborted' || signal.aborted) {
      return { aborted: true, total: 0, backedUp: 0, missing: [], suggestedFolders: [], sources: [] };
    }
    throw e;
  }
});

ipcMain.handle('list-existing-folders', (_event, nasPath: string) => {
  return listExistingFolders(nasPath);
});

let transferAbort: AbortController | null = null;

function notifyTransferDone(fileCount: number, errorCount: number) {
  if (!Notification.isSupported()) return;
  const body = errorCount > 0
    ? `${fileCount} files copied, ${errorCount} failed`
    : `${fileCount} files copied`;
  new Notification({ title: 'Transfer complete', body }).show();
}

ipcMain.handle('transfer', async (_event, files: FileInfo[], dest: string, mode: string, topic?: string, cameraSubfolder?: boolean, fileGroups?: {dest: string, files: FileInfo[]}[]) => {
  transferAbort = new AbortController();
  const { signal } = transferAbort;
  const sleepBlockId = powerSaveBlocker.start('prevent-app-suspension');
  const dateFormat = getSetting('dateFormat') || undefined;

  // Pre-flight: bail out before copying if the destination volume(s) lack space.
  const spaceTargets = (fileGroups && fileGroups.length > 0)
    ? fileGroups
    : [{ dest, files }];
  const shortfall = await checkDiskSpace(spaceTargets);
  if (shortfall) {
    powerSaveBlocker.stop(sleepBlockId);
    transferAbort = null;
    return { errors: [], cancelled: false, insufficientSpace: shortfall };
  }

  // Build the full job list up front so progress totals (files and bytes)
  // cover the whole transfer regardless of mode.
  const jobs: CopyJob[] = [];
  const addForDest = (groupFiles: FileInfo[], groupDest: string) => {
    if (cameraSubfolder) {
      for (const [camera, cameraFiles] of groupByCamera(groupFiles)) {
        if (mode === 'grouped' && !fileGroups?.length) {
          jobs.push(...dateGroupedJobs(cameraFiles, path.join(groupDest, camera), topic ?? '', dateFormat));
        } else {
          jobs.push(...flatJobs(cameraFiles, path.join(groupDest, camera)));
        }
      }
    } else if (mode === 'grouped' && !fileGroups?.length) {
      jobs.push(...dateGroupedJobs(groupFiles, groupDest, topic ?? '', dateFormat));
    } else {
      jobs.push(...flatJobs(groupFiles, groupDest));
    }
  };
  if (fileGroups && fileGroups.length > 0) {
    for (const group of fileGroups) addForDest(group.files, group.dest);
  } else {
    addForDest(files, dest);
  }

  try {
    const errors = await copyBatch(jobs, (p) => {
      mainWindow?.webContents.send('transfer-progress', p);
      mainWindow?.setProgressBar(p.bytesTotal > 0 ? p.bytesDone / p.bytesTotal : -1);
    }, signal);
    if (!signal.aborted) notifyTransferDone(jobs.length - errors.length, errors.length);
    return { errors, cancelled: signal.aborted };
  } finally {
    mainWindow?.setProgressBar(-1);
    powerSaveBlocker.stop(sleepBlockId);
    transferAbort = null;
  }
});

ipcMain.handle('cancel-transfer', () => {
  transferAbort?.abort();
});

ipcMain.handle('get-setting', (_event, key: string) => {
  return getSetting(key as any);
});

ipcMain.handle('set-setting', (_event, key: string, value: any) => {
  setSetting(key as any, value);
});

ipcMain.handle('describe-image', async (_event, filePath: string) => {
  const apiKey = getSetting('geminiKey');
  if (!apiKey) {
    console.log('[Gemini] No API key configured');
    return { ok: false, error: 'No Gemini API key configured' };
  }

  try {
    console.log(`[Gemini] Reading image: ${filePath}`);
    const fs = await import('node:fs');
    const imageBuffer = await fs.promises.readFile(filePath);
    const base64 = imageBuffer.toString('base64');
    const ext = filePath.split('.').pop()?.toLowerCase() ?? 'jpeg';
    const mimeMap: Record<string, string> = {
      jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', heic: 'image/heic',
      heif: 'image/heif', tiff: 'image/tiff', tif: 'image/tiff',
    };
    const mimeType = mimeMap[ext] ?? 'image/jpeg';
    console.log(`[Gemini] Image size: ${(imageBuffer.length / 1024 / 1024).toFixed(1)}MB, type: ${mimeType}`);

    const url = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent';
    const body = JSON.stringify({
      contents: [{
        parts: [
          { text: 'Describe this photo in at most 5 words. Only respond with the description, nothing else. Use lowercase.' },
          { inlineData: { mimeType, data: base64 } },
        ],
      }],
    });

    console.log('[Gemini] Sending request...');
    const resp = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': apiKey },
      body,
    });

    if (!resp.ok) {
      const text = await resp.text();
      console.error(`[Gemini] API error ${resp.status}: ${text.slice(0, 500)}`);
      return { ok: false, error: `Gemini API ${resp.status}: ${text.slice(0, 200)}` };
    }

    const json = await resp.json() as any;
    const text = json.candidates?.[0]?.content?.parts?.[0]?.text?.trim() ?? '';
    console.log(`[Gemini] Success: "${text}"`);
    return { ok: true, description: text };
  } catch (e: any) {
    console.error(`[Gemini] Exception: ${e.message}`);
    return { ok: false, error: e.message };
  }
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

// --- Folder Sync ---

ipcMain.handle('sync-scan', async (_event, sourcePath: string, destPath: string) => {
  const fs = await import('node:fs');
  if (!fs.existsSync(sourcePath)) {
    throw new Error('Source folder not found or unreachable');
  }
  if (!fs.existsSync(path.dirname(destPath))) {
    throw new Error('Destination not online or unreachable');
  }

  mainWindow?.webContents.send('sync-progress', { step: 'source', count: 0, folder: 'Scanning source...' });
  const sourceFiles = await walkFolder(sourcePath, (count, folder) => {
    mainWindow?.webContents.send('sync-progress', { step: 'source', count, folder });
  });

  mainWindow?.webContents.send('sync-progress', { step: 'dest', count: 0, folder: 'Scanning destination...' });
  const destFiles = await walkFolder(destPath, (count, folder) => {
    mainWindow?.webContents.send('sync-progress', { step: 'dest', count, folder });
  });

  const diff = diffFolders(sourceFiles, destFiles);
  return {
    added: diff.added,
    changed: diff.changed,
    unchanged: diff.unchanged,
    sourceTotal: sourceFiles.length,
    destTotal: destFiles.length,
  };
});

let syncAbort: AbortController | null = null;

ipcMain.handle('sync-transfer', async (_event, files: any[], destRoot: string) => {
  syncAbort = new AbortController();
  const { signal } = syncAbort;
  const sleepBlockId = powerSaveBlocker.start('prevent-app-suspension');

  try {
    const errors = await syncFiles(files, destRoot, (current, total, name) => {
      mainWindow?.webContents.send('sync-transfer-progress', { current, total, name });
    }, signal);
    return { errors, cancelled: signal.aborted };
  } finally {
    powerSaveBlocker.stop(sleepBlockId);
    syncAbort = null;
  }
});

ipcMain.handle('cancel-sync', () => {
  syncAbort?.abort();
});
