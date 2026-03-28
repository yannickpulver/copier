import './index.css';

declare global {
  interface Window {
    api: {
      listSdCards: () => Promise<{ name: string; path: string }[]>;
      loadSynologyConfig: () => Promise<{ available: boolean; folders: string[] }>;
      checkSourcesStatus: () => Promise<void>;
      onSourcesList: (cb: (sources: { name: string; type: string }[]) => void) => () => void;
      onSourceStatus: (cb: (data: { index: number; available: boolean }) => void) => () => void;
      scan: (sdPath: string, skipCheck?: boolean) => Promise<{
        total: number;
        backedUp: number;
        missing: { name: string; size: number; fullPath: string; captureDate?: string; isMedia?: boolean }[];
        suggestedFolders: { folder: string; count: number; source: string }[];
        sources: { name: string; ok: boolean; error?: string }[];
      }>;
      listExistingFolders: (nasPath: string) => Promise<string[]>;
      transfer: (files: any[], dest: string, mode: string, topic?: string, cameraSubfolder?: boolean, fileGroups?: {dest: string, files: any[]}[]) => Promise<{ errors: string[]; cancelled: boolean }>;
      cancelTransfer: () => Promise<void>;
      testSynology: (host: string, port: number, user: string, pass: string, secure: boolean, folders: string) => Promise<{ ok: boolean; error?: string }>;
      describeImage: (filePath: string) => Promise<{ ok: boolean; description?: string; error?: string }>;
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
const sourcesStatus = $('#sources-status');
const scanBtn = $<HTMLButtonElement>('#scan-btn');
const instantTransferBtn = $<HTMLButtonElement>('#instant-transfer-btn');
const status = $('#status');
const fileList = $<HTMLDivElement>('#file-list');
const transferSection = $('#transfer-section');
const newFolderInput = $<HTMLInputElement>('#new-folder-name');
const existingSelect = $<HTMLDivElement>('#existing-folders');
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

const MIN_SESSION_GAP_MS = 15 * 60 * 1000; // 15 min minimum to consider a break

/** Split files into sessions by detecting natural time gaps within a day. */
function detectSessions(files: any[]): Map<string, any[]> {
  const byDay = new Map<string, any[]>();
  for (const f of files) {
    const day = f.captureDate
      ? new Date(f.captureDate).toISOString().slice(0, 10)
      : 'unknown';
    const arr = byDay.get(day);
    if (arr) arr.push(f);
    else byDay.set(day, [f]);
  }

  const sessions = new Map<string, any[]>();
  for (const [day, dayFiles] of byDay) {
    if (day === 'unknown') {
      sessions.set('unknown', dayFiles);
      continue;
    }

    const sorted = [...dayFiles].sort((a, b) =>
      new Date(a.captureDate).getTime() - new Date(b.captureDate).getTime()
    );

    if (sorted.length < 2) {
      sessions.set(day, sorted);
      continue;
    }

    // Compute gaps between consecutive files
    const gaps: number[] = [];
    for (let i = 1; i < sorted.length; i++) {
      gaps.push(new Date(sorted[i].captureDate).getTime() - new Date(sorted[i - 1].captureDate).getTime());
    }

    // Find natural break: biggest ratio jump in sorted gap distribution
    const sortedGaps = [...gaps].sort((a, b) => a - b);
    let splitThreshold = Infinity;
    let bestRatio = 3; // need at least 3x jump
    for (let i = 1; i < sortedGaps.length; i++) {
      if (sortedGaps[i] < MIN_SESSION_GAP_MS) continue;
      const ratio = sortedGaps[i] / Math.max(sortedGaps[i - 1], 1000);
      if (ratio >= bestRatio) {
        bestRatio = ratio;
        splitThreshold = sortedGaps[i];
      }
    }

    // Split into sessions at detected gaps
    let sessionIdx = 0;
    let currentSession: any[] = [sorted[0]];
    for (let i = 1; i < sorted.length; i++) {
      if (gaps[i - 1] >= splitThreshold) {
        const key = `${day}#${sessionIdx}`;
        sessions.set(key, currentSession);
        sessionIdx++;
        currentSession = [];
      }
      currentSession.push(sorted[i]);
    }
    const key = sessionIdx === 0 ? day : `${day}#${sessionIdx}`;
    sessions.set(key, currentSession);
  }

  return sessions;
}

function sessionLabel(key: string): string {
  if (key === 'unknown') return 'Unknown date';
  const [day, idx] = key.split('#');
  const dateStr = day.replace(/-/g, '.');
  if (idx === undefined) return dateStr;
  const suffix = String.fromCharCode(97 + parseInt(idx)); // a, b, c...
  return `${dateStr}${suffix}`;
}

function sessionDatePrefix(key: string): string {
  const [day, idx] = key.split('#');
  const dateStr = day.replace(/-/g, '.');
  if (idx === undefined) return dateStr;
  const suffix = String.fromCharCode(97 + parseInt(idx));
  return `${dateStr}${suffix}`;
}

const spinner = '<span class="inline-block w-2.5 h-2.5 border border-neutral-500 border-t-transparent rounded-full animate-spin shrink-0"></span>';

function renderSourcesPending(sources: { name: string; type: string }[]) {
  if (sources.length === 0) {
    sourcesStatus.innerHTML = '<span class="text-xs text-neutral-500">No sources — open ⚙</span>';
    return;
  }
  sourcesStatus.innerHTML = sources.map((s, i) => {
    const label = s.type === 'fallback' ? `${escapeHtml(s.name)} (fallback)` : escapeHtml(s.name);
    return `<span id="source-pill-${i}" class="flex items-center gap-1.5 bg-neutral-800 border border-neutral-700 rounded px-2 py-1 text-xs text-neutral-500">${spinner} ${label}</span>`;
  }).join('');
}

function resolveSourcePill(index: number, available: boolean) {
  const pill = document.getElementById(`source-pill-${index}`);
  if (!pill) return;
  const dot = available
    ? '<span class="w-1.5 h-1.5 rounded-full bg-green-500 shrink-0"></span>'
    : '<span class="w-1.5 h-1.5 rounded-full bg-neutral-600 shrink-0"></span>';
  const spinnerEl = pill.querySelector('.animate-spin');
  if (spinnerEl) spinnerEl.outerHTML = dot;
  pill.className = pill.className.replace('text-neutral-500', available ? 'text-neutral-300' : 'text-neutral-500');
}

// Listen for per-source updates
window.api.onSourcesList((sources) => {
  renderSourcesPending(sources);
  document.getElementById('sources-loader')?.remove();
  document.getElementById('actions-row')?.classList.remove('hidden');
});

window.api.onSourceStatus(({ index, available }) => {
  resolveSourcePill(index, available);
});

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
  // Fire all in parallel, each section resolves independently
  const destsPromise = Promise.all([
    window.api.getSetting('transferDests'),
    window.api.getSetting('transferDest'),
  ]).then(([savedDests, oldDest]) => {
    transferDests = savedDests ?? (oldDest ? [oldDest] : []);
    if (!savedDests && oldDest) {
      window.api.setSetting('transferDests', transferDests);
    }
    populateTransferDests();
  });

  const sdPromise = refreshSdCards().then(() => {
    document.getElementById('sd-loader')?.remove();
  });

  const sourcesPromise = window.api.checkSourcesStatus();

  await Promise.all([destsPromise, sdPromise, sourcesPromise]);

  setInterval(refreshSdCards, 3000);
  setInterval(() => window.api.checkSourcesStatus(), 10000);
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
    } else {
      // SD card changed — reset results
      resetResults();
    }
    scanBtn.disabled = cards.length === 0;
    instantTransferBtn.disabled = cards.length === 0;
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
  if (missingFiles.length > 0) {
    renderSessionFolderMappings(missingFiles, folders);
  } else {
    existingSelect.innerHTML = '';
  }
}

function groupFilesByDate(files: any[]): Map<string, any[]> {
  const groups = new Map<string, any[]>();
  for (const f of files) {
    const date = f.captureDate
      ? new Date(f.captureDate).toISOString().slice(0, 10).replace(/-/g, '.')
      : 'unknown';
    const arr = groups.get(date);
    if (arr) arr.push(f);
    else groups.set(date, [f]);
  }
  return groups;
}

function renderSessionFolderMappings(files: any[], existingFolders: string[]) {
  const sessions = detectSessions(files);
  const reversedFolders = [...existingFolders].reverse();
  const folderOptions = [
    '<option value="">— skip —</option>',
    ...reversedFolders.map((f) => `<option value="${escapeHtml(f)}">${escapeHtml(f)}</option>`),
  ].join('');

  existingSelect.innerHTML = [...sessions.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, sessionFiles]) => {
      const label = sessionLabel(key);
      const datePrefix = key.split('#')[0].replace(/-/g, '.');
      const match = reversedFolders.find((f) => f.startsWith(datePrefix)) ?? '';
      const opts = folderOptions.replace(
        `value="${escapeHtml(match)}"`,
        `value="${escapeHtml(match)}" selected`,
      );
      return `<div class="flex items-center gap-2" data-session="${escapeHtml(key)}">
        <span class="text-[11px] text-neutral-400 w-28 shrink-0">${escapeHtml(label)} <span class="text-neutral-500">(${sessionFiles.length})</span></span>
        <select class="date-folder-select flex-1 bg-neutral-800 border border-neutral-700 rounded px-2 py-0.5 text-[11px] text-neutral-300 focus:outline-none focus:border-blue-500">${opts}</select>
      </div>`;
    })
    .join('');
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

function resetResults() {
  missingFiles = [];
  fileList.innerHTML = '';
  otherList.innerHTML = '';
  allBackedUp.classList.add('hidden');
  fileTable.classList.add('hidden');
  otherSection.classList.add('hidden');
  transferSection.classList.add('hidden');
  progressBar.style.width = '0%';
  progressLabel.textContent = '';
  status.textContent = '';
}

async function runScan(skipCheck: boolean) {
  const sdPath = sdSelect.value;
  if (!sdPath) return;

  scanBtn.disabled = true;
  instantTransferBtn.disabled = true;
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

    // Group by session (time-gap aware)
    const sessionGroups = detectSessions(media);
    const sortedSessions = [...sessionGroups.entries()].sort((a, b) => b[0].localeCompare(a[0]));

    fileList.innerHTML = sortedSessions.map(([key, files]) => {
      const label = sessionLabel(key);
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

      // Build session groups preview
      const sessionCounts = [...sessionGroups.entries()]
        .filter(([k]) => k !== 'unknown')
        .sort((a, b) => b[0].localeCompare(a[0]));
      dateGroupsPreview.innerHTML = sessionCounts.map(([key, files]) => {
        const label = sessionLabel(key);
        const hasMultipleSessions = key.includes('#') || sessionCounts.some(([k]) => k !== key && k.split('#')[0] === key.split('#')[0]);
        return `<div class="flex items-center gap-1.5 bg-neutral-800 border border-neutral-700 rounded px-2 py-1 text-[10px] text-neutral-300">
          <input type="checkbox" checked data-session="${key}" class="date-filter-cb accent-blue-500 w-3 h-3" />
          <span>${label}</span>
          <span class="text-neutral-500">(${files.length})</span>
          ${hasMultipleSessions ? `<input type="text" data-session-topic="${key}" placeholder="topic" class="session-topic bg-neutral-900 border border-neutral-700 rounded px-1.5 py-0.5 text-[10px] w-24 focus:outline-none focus:border-blue-500" />` : ''}
        </div>`;
      }).join('');

      // Update transfer button count when session selection changes
      dateGroupsPreview.addEventListener('change', () => {
        const count = getFilteredFiles().length;
        transferBtn.textContent = `Transfer ${count} files`;
      });

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

      // Populate existing folders from transfer dest with date-group mapping
      const destPath = transferDest.value;
      if (destPath) {
        const folders = await window.api.listExistingFolders(destPath);
        renderSessionFolderMappings(media, folders);
      }

      // Determine transfer mode suggestion
      const hasMapping = [...existingSelect.querySelectorAll<HTMLSelectElement>('.date-folder-select')]
        .some((s) => s.value !== '');
      let suggestedMode: string;
      if (hasMapping) {
        suggestedMode = 'existing';
      } else {
        const suggestion = suggestTransferMode(media);
        suggestedMode = suggestion.mode;
        if (suggestion.folderName) {
          newFolderInput.value = suggestion.folderName;
        }
      }

      const radio = document.querySelector<HTMLInputElement>(`input[name="xfer-mode"][value="${suggestedMode}"]`);
      if (radio) radio.checked = true;
      dateGroupsPreview.classList.toggle('hidden', suggestedMode !== 'grouped');
      existingSelect.classList.toggle('hidden', suggestedMode !== 'existing');

      // Gemini: describe a sample image to suggest a topic
      const geminiKey = await window.api.getSetting('geminiKey');
      if (geminiKey) {
        const imageExts = new Set(['.jpg', '.jpeg', '.heic', '.heif', '.png', '.tiff', '.tif']);
        const images = media.filter((f: any) => {
          const ext = f.name.split('.').pop()?.toLowerCase() ?? '';
          return imageExts.has(`.${ext}`);
        });
        if (images.length > 0) {
          const sample = images[Math.floor(images.length / 2)];
          status.textContent = 'AI: describing images...';
          const desc = await window.api.describeImage(sample.fullPath);
          if (desc.ok && desc.description) {
            topicInput.value = desc.description;
            // Also append to new folder name if it ends with " - "
            if (newFolderInput.value.endsWith(' - ')) {
              newFolderInput.value += desc.description;
            }
            status.textContent = `AI suggested: ${desc.description}`;
          }
        }
      }
    }
  } catch (e: any) {
    status.textContent = `Error: ${e.message}`;
  } finally {
    scanBtn.disabled = false;
    instantTransferBtn.disabled = false;
  }
}

scanBtn.addEventListener('click', () => runScan(false));
instantTransferBtn.addEventListener('click', () => runScan(true));

// Toggle date groups preview
document.querySelectorAll<HTMLInputElement>('input[name="xfer-mode"]').forEach((radio) => {
  radio.addEventListener('change', () => {
    const selected = document.querySelector<HTMLInputElement>('input[name="xfer-mode"]:checked');
    dateGroupsPreview.classList.toggle('hidden', selected?.value !== 'grouped');
    existingSelect.classList.toggle('hidden', selected?.value !== 'existing');
  });
});

// --- Transfer ---

window.api.onTransferProgress(({ current, total }) => {
  const pct = total > 0 ? (current / total) * 100 : 0;
  progressBar.style.width = `${pct}%`;
  progressLabel.textContent = `${current}/${total}`;
});

transferBtn.addEventListener('click', async () => {
  const mode = (document.querySelector<HTMLInputElement>('input[name="xfer-mode"]:checked'))?.value ?? 'new';
  const filesToTransfer = mode === 'grouped' ? getFilteredFiles() : missingFiles;
  if (!filesToTransfer.length) return;

  const basePath = transferDest.value;
  if (!basePath) return;

  let dest: string;
  let fileGroups: {dest: string, files: any[]}[] | undefined;
  if (mode === 'new') {
    const name = newFolderInput.value.trim();
    if (!name) return;
    dest = `${basePath}/${name}`;
  } else if (mode === 'existing') {
    const rows = [...existingSelect.querySelectorAll<HTMLDivElement>('[data-session]')];
    const mappings = rows
      .map((row) => ({
        session: row.dataset.session!,
        folder: row.querySelector<HTMLSelectElement>('.date-folder-select')!.value,
      }))
      .filter((m) => m.folder);
    if (mappings.length === 0) return;
    const sessions = detectSessions(filesToTransfer);
    dest = basePath;
    fileGroups = mappings
      .map((m) => ({ dest: `${basePath}/${m.folder}`, files: sessions.get(m.session) ?? [] }))
      .filter((g) => g.files.length > 0);
    if (fileGroups.length === 0) return;
  } else {
    // grouped mode — build session-aware file groups
    dest = basePath;
    const selected = getSelectedSessions();
    const sessions = detectSessions(filesToTransfer);
    const globalTopic = topicInput.value.trim();
    fileGroups = [];
    for (const [key, sFiles] of sessions) {
      if (!selected.has(key)) continue;
      const topicEl = dateGroupsPreview.querySelector<HTMLInputElement>(`[data-session-topic="${key}"]`);
      const sessionTopic = topicEl?.value.trim() || globalTopic;
      const prefix = sessionDatePrefix(key);
      const folderName = sessionTopic ? `${prefix} - ${sessionTopic}` : prefix;
      fileGroups.push({ dest: `${basePath}/${folderName}`, files: sFiles });
    }
    if (fileGroups.length === 0) return;
  }

  const topic = topicInput.value.trim();
  const cancelBtn = $<HTMLButtonElement>('#cancel-transfer-btn');
  transferBtn.disabled = true;
  scanBtn.disabled = true;
  instantTransferBtn.disabled = true;
  cancelBtn.classList.remove('hidden');
  progressBar.style.width = '0%';

  try {
    const cameraSubfolder = $<HTMLInputElement>('#camera-subfolder').checked;
    const result = await window.api.transfer(filesToTransfer, dest, mode, topic, cameraSubfolder, fileGroups);
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
    scanBtn.disabled = false;
    instantTransferBtn.disabled = false;
    cancelBtn.classList.add('hidden');
  }
});

$<HTMLButtonElement>('#cancel-transfer-btn').addEventListener('click', () => {
  window.api.cancelTransfer();
});

// --- Smart suggestion ---

function suggestTransferMode(
  missing: { captureDate?: string }[],
): { mode: string; folderName?: string } {
  const sessions = detectSessions(missing);
  const sessionKeys = [...sessions.keys()].filter(k => k !== 'unknown');

  if (sessionKeys.length <= 1) {
    const key = sessionKeys[0];
    const dateStr = key
      ? sessionDatePrefix(key)
      : new Date().toISOString().slice(0, 10).replace(/-/g, '.');
    return { mode: 'new', folderName: `${dateStr} - ` };
  }

  return { mode: 'grouped' };
}

// --- Date filtering ---

function getSelectedSessions(): Set<string> {
  const cbs = dateGroupsPreview.querySelectorAll<HTMLInputElement>('.date-filter-cb:checked');
  return new Set([...cbs].map(cb => cb.dataset.session!));
}

function getFilteredFiles(): typeof missingFiles {
  const selected = getSelectedSessions();
  if (selected.size === 0) return [];
  const sessions = detectSessions(missingFiles);
  const result: any[] = [];
  for (const [key, files] of sessions) {
    if (selected.has(key)) result.push(...files);
  }
  return result;
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

function updateCardSummaries(host: string, folders: string, geminiKey?: string) {
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

  const geminiOk = !!(geminiKey);
  document.getElementById('card-gemini-dot')!.className =
    `w-2 h-2 rounded-full shrink-0 ${geminiOk ? 'bg-green-500' : 'bg-neutral-600'}`;
  document.getElementById('card-gemini-summary')!.textContent =
    geminiOk ? 'API key set' : 'Not configured';
}

settingsToggle.addEventListener('click', async () => {
  const isOpen = !settingsPanel.classList.contains('hidden');
  if (isOpen) {
    settingsPanel.classList.add('hidden');
    mainContent.classList.remove('hidden');
  } else {
    const cfgPathsList = document.getElementById('cfg-paths-list')!;
    const cfgDestsList = document.getElementById('cfg-dests-list')!;

    const [host, port, user, pass, folders, secure, checkPaths, savedDests, geminiKey] = await Promise.all([
      window.api.getSetting('synologyHost'),
      window.api.getSetting('synologyPort'),
      window.api.getSetting('synologyUser'),
      window.api.getSetting('synologyPass'),
      window.api.getSetting('synologyFolders'),
      window.api.getSetting('synologySecure'),
      window.api.getSetting('checkPaths'),
      window.api.getSetting('transferDests'),
      window.api.getSetting('geminiKey'),
    ]);
    cfgHost.value = host ?? '';
    cfgPort.value = String(port ?? 5001);
    cfgUser.value = user ?? '';
    cfgPass.value = pass ?? '';
    cfgFolders.value = folders ?? '';
    cfgSecure.checked = secure ?? true;
    $<HTMLInputElement>('#cfg-gemini-key').value = geminiKey ?? '';

    currentCheckPaths = normalizeCheckPaths(checkPaths);
    renderPathChips(cfgPathsList);

    currentTransferDests = savedDests ?? [...transferDests];
    renderDestChips(cfgDestsList);

    // Collapse all detail sections
    document.querySelectorAll('[id^="card-"][id$="-detail"]').forEach((d) => d.classList.add('hidden'));

    updateCardSummaries(host ?? '', folders ?? '', geminiKey ?? '');

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
    window.api.setSetting('geminiKey', $<HTMLInputElement>('#cfg-gemini-key').value || undefined),
  ]);

  // Sync transfer dests to main screen
  transferDests = [...currentTransferDests];
  populateTransferDests();

  settingsPanel.classList.add('hidden');
  mainContent.classList.remove('hidden');

  window.api.checkSourcesStatus();
});

init();
