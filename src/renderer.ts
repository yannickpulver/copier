import './index.css';

declare global {
  interface Window {
    api: {
      listSdCards: () => Promise<{ name: string; path: string }[]>;
      loadSynologyConfig: () => Promise<{ available: boolean; folders: string[] }>;
      scan: (sdPath: string, skipCheck?: boolean) => Promise<{
        total: number;
        backedUp: number;
        missing: { name: string; size: number; fullPath: string; captureDate?: string; isMedia?: boolean }[];
        suggestedFolders: { folder: string; count: number; source: string }[];
        sources: { name: string; ok: boolean; error?: string }[];
      }>;
      listExistingFolders: (nasPath: string) => Promise<string[]>;
      transfer: (files: any[], dest: string, mode: string, topic?: string, cameraSubfolder?: boolean) => Promise<{ errors: string[]; cancelled: boolean }>;
      cancelTransfer: () => Promise<void>;
      testSynology: (host: string, port: number, user: string, pass: string, secure: boolean, folders: string) => Promise<{ ok: boolean; error?: string }>;
      browseFolder: (defaultPath?: string) => Promise<string | null>;
      revealFile: (filePath: string) => void;
      findAndOpenFolder: (folderName: string, searchBase: string) => Promise<boolean>;
      getSetting: (key: string) => Promise<any>;
      setSetting: (key: string, value: any) => Promise<void>;
      onScanProgress: (cb: (data: { step: string; count: number; folder: string }) => void) => () => void;
      onTransferProgress: (cb: (data: { current: number; total: number; name: string }) => void) => () => void;
    };
  }
}

const $ = <T extends HTMLElement>(sel: string) => document.querySelector<T>(sel)!;

const sdSelect = $<HTMLSelectElement>('#sd-select');
const sourcesSummary = $('#sources-summary');
const scanBtn = $<HTMLButtonElement>('#scan-btn');
const status = $('#status');
const fileList = $<HTMLDivElement>('#file-list');
const transferSection = $('#transfer-section');
const newFolderInput = $<HTMLInputElement>('#new-folder-name');
const existingSelect = $<HTMLSelectElement>('#existing-folders');
const topicInput = $<HTMLInputElement>('#topic');
const dateGroupsPreview = $('#date-groups-preview');
const transferDest = $<HTMLSelectElement>('#transfer-dest');
const browseDestBtn = $('#browse-dest-btn');
const transferBtn = $<HTMLButtonElement>('#transfer-btn');
const progressBar = $<HTMLDivElement>('#progress-bar');
const progressLabel = $('#progress-label');
const allBackedUp = $('#all-backed-up');
const backedUpMsg = $('#backed-up-msg');
const fileTable = $('#file-table');
const otherSection = $('#other-section');
const otherLabel = $('#other-label');
const otherList = $<HTMLTableSectionElement>('#other-list');

let sdCards: { name: string; path: string }[] = [];
let missingFiles: any[] = [];

function updateSourcesSummary(apiAvailable: boolean, checkPaths: { path: string; fallbackOnly?: boolean }[]) {
  const parts: string[] = [];
  if (apiAvailable) parts.push('Synology API');
  for (const cp of checkPaths) {
    const name = cp.path.split('/').pop() ?? cp.path;
    parts.push(cp.fallbackOnly ? `${name} (if offline)` : name);
  }
  sourcesSummary.textContent = parts.length ? parts.join(', ') : 'No sources — open ⚙';
}

function normalizeCheckPaths(raw: any): { path: string; fallbackOnly?: boolean }[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((item: any) => {
    if (typeof item === 'string') return { path: item };
    if (item && typeof item.path === 'string') return item;
    return null;
  }).filter(Boolean);
}

// --- Init ---

let transferDests: string[] = [];

function populateTransferDests() {
  transferDest.innerHTML = transferDests.length
    ? transferDests.map((d) => `<option value="${escapeHtml(d)}">${escapeHtml(d.split('/').pop() ?? d)}</option>`).join('')
    : '<option value="">No destinations — open ⚙</option>';
}

async function init() {
  const [config, savedDests, oldDest, rawCheckPaths] = await Promise.all([
    window.api.loadSynologyConfig(),
    window.api.getSetting('transferDests'),
    window.api.getSetting('transferDest'),
    window.api.getSetting('checkPaths'),
    refreshSdCards(),
  ]);

  // Migrate old single dest to array
  transferDests = savedDests ?? (oldDest ? [oldDest] : []);
  if (!savedDests && oldDest) {
    window.api.setSetting('transferDests', transferDests);
  }
  populateTransferDests();

  const savedCheckPaths = normalizeCheckPaths(rawCheckPaths);
  updateSourcesSummary(config.available, savedCheckPaths);

  document.getElementById('loader')!.classList.add('hidden');
  document.getElementById('main-content')!.classList.remove('hidden');

  setInterval(refreshSdCards, 3000);
}

async function refreshSdCards() {
  const cards = await window.api.listSdCards();
  const paths = cards.map((c) => c.path).join(',');
  const oldPaths = sdCards.map((c) => c.path).join(',');

  if (paths !== oldPaths) {
    sdCards = cards;
    const prev = sdSelect.value;
    sdSelect.innerHTML = cards.length
      ? cards.map((c) => `<option value="${c.path}">${c.name} (${c.path})</option>`).join('')
      : '<option value="">No SD card detected</option>';

    if (cards.find((c) => c.path === prev)) {
      sdSelect.value = prev;
    }
    scanBtn.disabled = cards.length === 0;
  }
}

browseDestBtn.addEventListener('click', async () => {
  const path = await window.api.browseFolder(transferDest.value || undefined);
  if (path && !transferDests.includes(path)) {
    transferDests.push(path);
    window.api.setSetting('transferDests', transferDests);
    populateTransferDests();
    transferDest.value = path;
    await refreshExistingFolders();
  }
});

transferDest.addEventListener('change', async () => {
  await refreshExistingFolders();
});

async function refreshExistingFolders() {
  const dest = transferDest.value;
  if (!dest) {
    existingSelect.innerHTML = '';
    return;
  }
  const folders = await window.api.listExistingFolders(dest);
  existingSelect.innerHTML = folders
    .map((f) => `<option value="${f}">${f}</option>`)
    .join('');
  if (folders.length) existingSelect.value = folders[folders.length - 1];
}

// --- Scan ---

window.api.onScanProgress(({ step, count, folder }) => {
  if (step === 'sd') {
    status.textContent = `SD: ${count} files — ${folder}`;
  } else if (step === 'source') {
    status.textContent = `${folder} (${count})`;
  } else if (step === 'dates') {
    status.textContent = `Reading dates: ${folder}`;
  }
});

scanBtn.addEventListener('click', async () => {
  const sdPath = sdSelect.value;
  if (!sdPath) return;

  const skipCheck = $<HTMLInputElement>('#skip-check').checked;

  scanBtn.disabled = true;
  status.textContent = skipCheck ? 'Scanning files...' : 'Starting scan...';
  fileList.innerHTML = '';
  otherList.innerHTML = '';
  allBackedUp.classList.add('hidden');
  fileTable.classList.add('hidden');
  otherSection.classList.add('hidden');
  transferSection.classList.add('hidden');

  try {
    const result = await window.api.scan(sdPath, skipCheck);

    const media = result.missing.filter((f) => f.isMedia !== false);
    const other = result.missing.filter((f) => f.isMedia === false);
    missingFiles = media;

    const failedSources = result.sources.filter((s) => !s.ok);
    const sourceInfo = failedSources.length ? ` (${failedSources.map((s) => s.name + ' failed').join(', ')})` : '';
    status.textContent = `${result.total} files — ${result.backedUp} backed up, ${media.length} new${other.length ? `, ${other.length} other` : ''}${sourceInfo}`;

    if (media.length === 0) {
      allBackedUp.classList.remove('hidden');
      backedUpMsg.textContent = `All ${result.backedUp} files backed up`;

      const backupFolders = document.getElementById('backup-folders')!;

      // Group folders by source
      const bySource = new Map<string, typeof result.suggestedFolders>();
      for (const sf of result.suggestedFolders) {
        const label = sf.source.split('/').pop() ?? sf.source;
        const existing = bySource.get(label);
        if (existing) existing.push(sf);
        else bySource.set(label, [sf]);
      }

      backupFolders.innerHTML = [...bySource.entries()].map(([source, folders]) => `
        <div class="space-y-1">
          <div class="text-[10px] text-neutral-500 uppercase tracking-wider">${escapeHtml(source)}</div>
          <div class="flex flex-wrap gap-1">
            ${folders.map((s) => {
              const name = s.folder.split('/').pop() ?? s.folder;
              return `<button data-folder="${escapeHtml(s.folder)}" class="px-2 py-1 bg-neutral-800 hover:bg-neutral-700 border border-neutral-700 rounded text-[11px] text-neutral-300 transition-colors">${escapeHtml(name)} <span class="text-neutral-500">(${s.count})</span></button>`;
            }).join('')}
          </div>
        </div>
      `).join('');

      backupFolders.addEventListener('click', async (e) => {
        const btn = (e.target as HTMLElement).closest<HTMLButtonElement>('button');
        if (!btn?.dataset.folder) return;
        const folderName = btn.dataset.folder.split('/').pop() ?? '';
        const searchBase = transferDest.value;
        if (searchBase && folderName) {
          const found = await window.api.findAndOpenFolder(folderName, searchBase);
          if (!found) status.textContent = `Folder "${folderName}" not found locally`;
        }
      });
    } else {
      fileTable.classList.remove('hidden');
    }

    // Group by day
    const byDay = new Map<string, typeof media>();
    for (const f of media) {
      const day = f.captureDate
        ? new Date(f.captureDate).toISOString().slice(0, 10)
        : 'unknown';
      const arr = byDay.get(day);
      if (arr) arr.push(f);
      else byDay.set(day, [f]);
    }
    const sortedDays = [...byDay.entries()].sort((a, b) => b[0].localeCompare(a[0]));

    fileList.innerHTML = sortedDays.map(([day, files]) => {
      const label = day === 'unknown' ? 'Unknown date' : day.replace(/-/g, '.');
      const totalSize = files.reduce((s, f) => s + f.size, 0);
      return `
        <details class="border border-neutral-700 rounded-md overflow-hidden">
          <summary class="flex items-center gap-3 px-3 py-2 bg-neutral-800/50 hover:bg-neutral-800 cursor-pointer text-xs">
            <span class="font-medium text-neutral-300">${label}</span>
            <span class="text-neutral-500">${files.length} file${files.length > 1 ? 's' : ''}</span>
            <span class="text-neutral-500 ml-auto">${formatSize(totalSize)}</span>
          </summary>
          <table class="w-full text-xs">
            <tbody class="divide-y divide-neutral-800">
              ${files.map((f: any) => `
                <tr class="hover:bg-neutral-800/50 cursor-pointer" data-path="${escapeHtml(f.fullPath)}">
                  <td class="px-3 py-1.5">${escapeHtml(f.name)}</td>
                  <td class="px-3 py-1.5 text-right text-neutral-400 w-16">${formatSize(f.size)}</td>
                  <td class="px-3 py-1.5 text-center text-neutral-400 w-20 truncate">${f.camera ? escapeHtml(f.camera) : ''}</td>
                  <td class="px-3 py-1.5 text-right text-neutral-500 w-12 text-[10px]">${f.captureDate ? formatTime(f.captureDate) : ''}</td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </details>
      `;
    }).join('');

    // Click to reveal in Finder
    fileList.addEventListener('click', (e) => {
      const row = (e.target as HTMLElement).closest('tr');
      if (row?.dataset.path) window.api.revealFile(row.dataset.path);
    });

    if (other.length > 0) {
      otherSection.classList.remove('hidden');
      otherLabel.textContent = `Likely not needed (${other.length} files)`;
      otherList.innerHTML = other.map((f) => `
        <tr class="hover:bg-neutral-800/50 cursor-pointer" data-path="${escapeHtml(f.fullPath)}">
          <td class="px-3 py-1.5">${escapeHtml(f.name)}</td>
          <td class="px-3 py-1.5 text-right text-neutral-400">${formatSize(f.size)}</td>
        </tr>
      `).join('');

      otherList.addEventListener('click', (e) => {
        const row = (e.target as HTMLElement).closest('tr');
        if (row?.dataset.path) window.api.revealFile(row.dataset.path);
      });
    }

    if (media.length > 0) {
      transferSection.classList.remove('hidden');
      transferBtn.textContent = `Transfer ${media.length} files`;

      // Build date groups preview
      const dateGroups = new Map<string, number>();
      for (const f of media as any[]) {
        if (f.captureDate) {
          const date = new Date(f.captureDate).toISOString().slice(0, 10).replace(/-/g, '.');
          dateGroups.set(date, (dateGroups.get(date) ?? 0) + 1);
        }
      }
      const sortedDates = [...dateGroups.entries()].sort((a, b) => b[0].localeCompare(a[0]));
      dateGroupsPreview.innerHTML = sortedDates.map(([date, count]) =>
        `<span class="bg-neutral-800 border border-neutral-700 rounded px-2 py-0.5 text-[10px] text-neutral-300">${date} <span class="text-neutral-500">(${count})</span></span>`
      ).join('');

      // Show camera subfolder option if cameras detected
      const cameras = new Set(media.map((f: any) => f.camera).filter(Boolean));
      const cameraSubfolderOption = document.getElementById('camera-subfolder-option')!;
      const cameraList = document.getElementById('camera-list')!;
      if (cameras.size > 0) {
        cameraSubfolderOption.classList.remove('hidden');
        cameraList.textContent = `(${[...cameras].join(', ')})`;
      } else {
        cameraSubfolderOption.classList.add('hidden');
      }

      // Smart transfer suggestion
      const suggestion = suggestTransferMode(media, result.suggestedFolders);

      // Set transfer destination if not already set

      // Populate existing folders from transfer dest if it's set
      const destPath = transferDest.value;
      if (destPath) {
        const folders = await window.api.listExistingFolders(destPath);
        existingSelect.innerHTML = folders
          .map((f) => `<option value="${f}">${f}</option>`)
          .join('');

        if (suggestion.mode === 'existing' && suggestion.folder) {
          const name = suggestion.folder.split('/').pop() ?? '';
          if (folders.includes(name)) {
            existingSelect.value = name;
          }
        } else if (folders.length) {
          existingSelect.value = folders[folders.length - 1];
        }
      }

      // Apply suggestion
      const radio = document.querySelector<HTMLInputElement>(`input[name="xfer-mode"][value="${suggestion.mode}"]`);
      if (radio) radio.checked = true;
      dateGroupsPreview.classList.toggle('hidden', suggestion.mode !== 'grouped');

      if (suggestion.mode === 'new' && suggestion.folderName) {
        newFolderInput.value = suggestion.folderName;
      }
    }
  } catch (e: any) {
    status.textContent = `Error: ${e.message}`;
  } finally {
    scanBtn.disabled = false;
  }
});

// Toggle date groups preview
document.querySelectorAll<HTMLInputElement>('input[name="xfer-mode"]').forEach((radio) => {
  radio.addEventListener('change', () => {
    const selected = document.querySelector<HTMLInputElement>('input[name="xfer-mode"]:checked');
    dateGroupsPreview.classList.toggle('hidden', selected?.value !== 'grouped');
  });
});

// --- Transfer ---

window.api.onTransferProgress(({ current, total }) => {
  const pct = total > 0 ? (current / total) * 100 : 0;
  progressBar.style.width = `${pct}%`;
  progressLabel.textContent = `${current}/${total}`;
});

transferBtn.addEventListener('click', async () => {
  if (!missingFiles.length) return;

  const basePath = transferDest.value;
  if (!basePath) return;
  const mode = (document.querySelector<HTMLInputElement>('input[name="xfer-mode"]:checked'))?.value ?? 'new';

  let dest: string;
  if (mode === 'new') {
    const name = newFolderInput.value.trim();
    if (!name) return;
    dest = `${basePath}/${name}`;
  } else if (mode === 'existing') {
    const name = existingSelect.value;
    if (!name) return;
    dest = `${basePath}/${name}`;
  } else {
    dest = basePath;
  }

  const topic = topicInput.value.trim();
  const cancelBtn = $<HTMLButtonElement>('#cancel-transfer-btn');
  transferBtn.disabled = true;
  cancelBtn.classList.remove('hidden');
  progressBar.style.width = '0%';

  try {
    const cameraSubfolder = $<HTMLInputElement>('#camera-subfolder').checked;
    const result = await window.api.transfer(missingFiles, dest, mode, topic, cameraSubfolder);
    if (result.cancelled) {
      progressLabel.textContent = 'Cancelled';
      status.textContent = 'Transfer cancelled';
    } else {
      progressBar.style.width = '100%';
      progressLabel.textContent = result.errors.length ? `Done — ${result.errors.length} errors` : 'Done!';
      status.textContent = 'Transfer complete — rescanning...';
      await new Promise((r) => setTimeout(r, 800));
      scanBtn.click();
    }
  } catch (e: any) {
    progressLabel.textContent = `Error: ${e.message}`;
  } finally {
    transferBtn.disabled = false;
    cancelBtn.classList.add('hidden');
  }
});

$<HTMLButtonElement>('#cancel-transfer-btn').addEventListener('click', () => {
  window.api.cancelTransfer();
});

// --- Smart suggestion ---

function suggestTransferMode(
  missing: { captureDate?: string }[],
  suggestedFolders: { folder: string; count: number }[],
): { mode: string; folder?: string; folderName?: string } {
  // Get unique dates from missing files
  const dates = new Set<string>();
  for (const f of missing) {
    if (f.captureDate) {
      dates.add(new Date(f.captureDate).toISOString().slice(0, 10));
    }
  }

  // Check if any suggested folder's date matches a missing file date
  for (const sf of suggestedFolders) {
    const folderName = sf.folder.split('/').pop() ?? '';
    const m = folderName.match(/^(\d{4})\.(\d{2})\.(\d{2})/);
    if (m) {
      const folderDate = `${m[1]}-${m[2]}-${m[3]}`;
      if (dates.has(folderDate)) {
        return { mode: 'existing', folder: sf.folder };
      }
    }
  }

  // No date match in existing folders → new folder or grouped
  if (dates.size <= 1) {
    // Use the missing files' date, not today's date
    const date = [...dates][0];
    const dateStr = date
      ? date.replace(/-/g, '.')
      : new Date().toISOString().slice(0, 10).replace(/-/g, '.');
    return { mode: 'new', folderName: `${dateStr} - ` };
  }

  // Multiple dates → group by date
  return { mode: 'grouped' };
}

// --- Helpers ---

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function formatDate(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// --- Settings panel ---

const settingsToggle = document.getElementById('settings-toggle')!;
const settingsPanel = document.getElementById('settings-panel')!;
const mainContent = document.getElementById('main-content')!;
const cfgHost = $<HTMLInputElement>('#cfg-host');
const cfgPort = $<HTMLInputElement>('#cfg-port');
const cfgUser = $<HTMLInputElement>('#cfg-user');
const cfgPass = $<HTMLInputElement>('#cfg-pass');
const cfgFolders = $<HTMLInputElement>('#cfg-folders');
const cfgSecure = $<HTMLInputElement>('#cfg-secure');
const cfgSave = document.getElementById('cfg-save')!;

// Card expand/collapse
document.querySelectorAll<HTMLButtonElement>('.settings-card-header').forEach((btn) => {
  btn.addEventListener('click', () => {
    const card = btn.dataset.card!;
    const detail = document.getElementById(`card-${card}-detail`)!;
    const isOpen = !detail.classList.contains('hidden');
    // Collapse all
    document.querySelectorAll('[id^="card-"][id$="-detail"]').forEach((d) => d.classList.add('hidden'));
    if (!isOpen) detail.classList.remove('hidden');
  });
});

function updateCardSummaries(host: string, folders: string) {
  const synoOk = !!(host);
  document.getElementById('card-synology-dot')!.className =
    `w-2 h-2 rounded-full shrink-0 ${synoOk ? 'bg-green-500' : 'bg-neutral-600'}`;
  document.getElementById('card-synology-summary')!.textContent =
    synoOk ? `${host} (${folders || 'no folders'})` : 'Not configured';

  const pathCount = currentCheckPaths.length;
  document.getElementById('card-paths-dot')!.className =
    `w-2 h-2 rounded-full shrink-0 ${pathCount > 0 ? 'bg-green-500' : 'bg-neutral-600'}`;
  document.getElementById('card-paths-summary')!.textContent =
    pathCount > 0 ? `${pathCount} path${pathCount > 1 ? 's' : ''}` : 'No paths configured';

  const destCount = currentTransferDests.length;
  document.getElementById('card-dests-dot')!.className =
    `w-2 h-2 rounded-full shrink-0 ${destCount > 0 ? 'bg-green-500' : 'bg-neutral-600'}`;
  document.getElementById('card-dests-summary')!.textContent =
    destCount > 0 ? currentTransferDests.map((d) => d.split('/').pop()).join(', ') : 'No destinations';
}

settingsToggle.addEventListener('click', async () => {
  const isOpen = !settingsPanel.classList.contains('hidden');
  if (isOpen) {
    settingsPanel.classList.add('hidden');
    mainContent.classList.remove('hidden');
  } else {
    const cfgPathsList = document.getElementById('cfg-paths-list')!;
    const cfgDestsList = document.getElementById('cfg-dests-list')!;

    const [host, port, user, pass, folders, secure, checkPaths, savedDests] = await Promise.all([
      window.api.getSetting('synologyHost'),
      window.api.getSetting('synologyPort'),
      window.api.getSetting('synologyUser'),
      window.api.getSetting('synologyPass'),
      window.api.getSetting('synologyFolders'),
      window.api.getSetting('synologySecure'),
      window.api.getSetting('checkPaths'),
      window.api.getSetting('transferDests'),
    ]);
    cfgHost.value = host ?? '';
    cfgPort.value = String(port ?? 5001);
    cfgUser.value = user ?? '';
    cfgPass.value = pass ?? '';
    cfgFolders.value = folders ?? '';
    cfgSecure.checked = secure ?? true;

    currentCheckPaths = normalizeCheckPaths(checkPaths);
    renderPathChips(cfgPathsList);

    currentTransferDests = savedDests ?? [...transferDests];
    renderDestChips(cfgDestsList);

    // Collapse all detail sections
    document.querySelectorAll('[id^="card-"][id$="-detail"]').forEach((d) => d.classList.add('hidden'));

    updateCardSummaries(host ?? '', folders ?? '');

    mainContent.classList.add('hidden');
    settingsPanel.classList.remove('hidden');
  }
});

let currentCheckPaths: { path: string; fallbackOnly?: boolean }[] = [];
let currentTransferDests: string[] = [];

function renderPathChips(container: HTMLElement) {
  container.innerHTML = currentCheckPaths.map((cp, i) => `
    <div class="flex items-center gap-1.5">
      <span class="flex-1 bg-neutral-800 border border-neutral-700 rounded px-2 py-1 text-xs text-neutral-300 truncate">${escapeHtml(cp.path)}</span>
      <label class="flex items-center gap-1 cursor-pointer shrink-0 text-[10px] text-neutral-500" title="Only scan if NAS API is not reachable">
        <input type="checkbox" data-fallback="${i}" ${cp.fallbackOnly ? 'checked' : ''} class="accent-blue-500 scale-75" />
        only if NAS offline
      </label>
      <button data-remove="${i}" class="text-neutral-600 hover:text-red-400 text-sm leading-none transition-colors px-1">×</button>
    </div>
  `).join('');

  container.querySelectorAll<HTMLButtonElement>('[data-remove]').forEach((btn) => {
    btn.addEventListener('click', () => {
      currentCheckPaths.splice(parseInt(btn.dataset.remove!), 1);
      renderPathChips(container);
    });
  });

  container.querySelectorAll<HTMLInputElement>('[data-fallback]').forEach((cb) => {
    cb.addEventListener('change', () => {
      currentCheckPaths[parseInt(cb.dataset.fallback!)].fallbackOnly = cb.checked;
    });
  });
}

function renderDestChips(container: HTMLElement) {
  container.innerHTML = currentTransferDests.map((d, i) => `
    <div class="flex items-center gap-1.5">
      <span class="flex-1 bg-neutral-800 border border-neutral-700 rounded px-2 py-1 text-xs text-neutral-300 truncate">${escapeHtml(d)}</span>
      <button data-remove-dest="${i}" class="text-neutral-600 hover:text-red-400 text-sm leading-none transition-colors px-1">×</button>
    </div>
  `).join('');

  container.querySelectorAll<HTMLButtonElement>('[data-remove-dest]').forEach((btn) => {
    btn.addEventListener('click', () => {
      currentTransferDests.splice(parseInt(btn.dataset.removeDest!), 1);
      renderDestChips(container);
    });
  });
}

document.getElementById('cfg-test-synology')!.addEventListener('click', async () => {
  const btn = $<HTMLButtonElement>('#cfg-test-synology');
  const resultEl = document.getElementById('cfg-test-result')!;
  btn.disabled = true;
  resultEl.textContent = 'Testing...';
  resultEl.className = 'text-[10px] text-neutral-400';
  const result = await window.api.testSynology(
    cfgHost.value, parseInt(cfgPort.value) || 5001, cfgUser.value, cfgPass.value, cfgSecure.checked, cfgFolders.value,
  );
  btn.disabled = false;
  if (result.ok) {
    resultEl.textContent = 'Connected';
    resultEl.className = 'text-[10px] text-green-400';
  } else {
    resultEl.textContent = result.error ?? 'Failed';
    resultEl.className = 'text-[10px] text-red-400';
  }
});

document.getElementById('cfg-add-path')!.addEventListener('click', async () => {
  const path = await window.api.browseFolder();
  if (path && !currentCheckPaths.some((cp) => cp.path === path)) {
    currentCheckPaths.push({ path });
    renderPathChips(document.getElementById('cfg-paths-list')!);
  }
});

document.getElementById('cfg-add-dest')!.addEventListener('click', async () => {
  const path = await window.api.browseFolder();
  if (path && !currentTransferDests.includes(path)) {
    currentTransferDests.push(path);
    renderDestChips(document.getElementById('cfg-dests-list')!);
  }
});

cfgSave.addEventListener('click', async () => {
  await Promise.all([
    window.api.setSetting('synologyHost', cfgHost.value || undefined),
    window.api.setSetting('synologyPort', cfgPort.value ? parseInt(cfgPort.value) : undefined),
    window.api.setSetting('synologyUser', cfgUser.value || undefined),
    window.api.setSetting('synologyPass', cfgPass.value || undefined),
    window.api.setSetting('synologyFolders', cfgFolders.value || undefined),
    window.api.setSetting('synologySecure', cfgSecure.checked),
    window.api.setSetting('checkPaths', currentCheckPaths.length ? currentCheckPaths as any : undefined),
    window.api.setSetting('transferDests', currentTransferDests.length ? currentTransferDests : undefined),
  ]);

  // Sync transfer dests to main screen
  transferDests = [...currentTransferDests];
  populateTransferDests();

  settingsPanel.classList.add('hidden');
  mainContent.classList.remove('hidden');

  const config = await window.api.loadSynologyConfig();
  updateSourcesSummary(config.available, currentCheckPaths);
});

init();
