// Generates a fake SD card fixture for dev mode at dev-fixtures/test-sd.
// Files are tiny placeholders; mtimes span multiple days so the
// session/date-grouping logic has something real to chew on.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dest = path.join(root, 'dev-fixtures', 'test-sd', 'DCIM', '100CANON');
fs.rmSync(path.join(root, 'dev-fixtures', 'test-sd'), { recursive: true, force: true });
fs.mkdirSync(dest, { recursive: true });

// [filename, daysAgo, hour]
const plan = [
  ['IMG_0001.JPG', 5, 9],
  ['IMG_0002.JPG', 5, 9],
  ['IMG_0003.CR3', 5, 14],   // later same day → second session
  ['IMG_0004.CR3', 5, 14],
  ['IMG_0005.JPG', 2, 11],   // different day → separate date group
  ['MVI_0006.MP4', 2, 11],
  ['MVI_0007.MOV', 2, 16],
];

let n = 0;
for (const [name, daysAgo, hour] of plan) {
  const full = path.join(dest, name);
  fs.writeFileSync(full, `placeholder ${name}\n`);
  const d = new Date();
  d.setDate(d.getDate() - daysAgo);
  d.setHours(hour, 0, 0, 0);
  fs.utimesSync(full, d, d);
  n++;
}

console.log(`Wrote ${n} files to ${dest}`);
