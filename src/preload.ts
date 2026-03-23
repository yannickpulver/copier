import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('api', {
  listSdCards: () => ipcRenderer.invoke('list-sd-cards'),
  loadSynologyConfig: () => ipcRenderer.invoke('load-synology-config'),
  checkSourcesStatus: () => ipcRenderer.invoke('check-sources-status'),
  onSourcesList: (cb: (sources: { name: string; type: string }[]) => void) => {
    const listener = (_event: any, data: any) => cb(data);
    ipcRenderer.on('sources-list', listener);
    return () => ipcRenderer.removeListener('sources-list', listener);
  },
  onSourceStatus: (cb: (data: { index: number; available: boolean }) => void) => {
    const listener = (_event: any, data: any) => cb(data);
    ipcRenderer.on('source-status', listener);
    return () => ipcRenderer.removeListener('source-status', listener);
  },
  scan: (sdPath: string, skipCheck?: boolean) => ipcRenderer.invoke('scan', sdPath, skipCheck),
  listExistingFolders: (nasPath: string) =>
    ipcRenderer.invoke('list-existing-folders', nasPath),
  transfer: (files: any[], dest: string, mode: string, topic?: string, cameraSubfolder?: boolean) =>
    ipcRenderer.invoke('transfer', files, dest, mode, topic, cameraSubfolder),
  cancelTransfer: () => ipcRenderer.invoke('cancel-transfer'),
  testSynology: (host: string, port: number, user: string, pass: string, secure: boolean, folders: string) =>
    ipcRenderer.invoke('test-synology', host, port, user, pass, secure, folders),
  describeImage: (filePath: string) =>
    ipcRenderer.invoke('describe-image', filePath) as Promise<{ ok: boolean; description?: string; error?: string }>,
  browseFolder: (defaultPath?: string) =>
    ipcRenderer.invoke('browse-folder', defaultPath),
  revealFile: (filePath: string) =>
    ipcRenderer.send('reveal-file', filePath),
  findAndOpenFolder: (folderName: string, searchBase: string) =>
    ipcRenderer.invoke('find-and-open-folder', folderName, searchBase),
  getSetting: (key: string) => ipcRenderer.invoke('get-setting', key),
  setSetting: (key: string, value: any) => ipcRenderer.invoke('set-setting', key, value),
  onScanProgress: (cb: (data: any) => void) => {
    const listener = (_event: any, data: any) => cb(data);
    ipcRenderer.on('scan-progress', listener);
    return () => ipcRenderer.removeListener('scan-progress', listener);
  },
  onTransferProgress: (cb: (data: any) => void) => {
    const listener = (_event: any, data: any) => cb(data);
    ipcRenderer.on('transfer-progress', listener);
    return () => ipcRenderer.removeListener('transfer-progress', listener);
  },
});
