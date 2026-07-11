import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import * as path from 'node:path';
import plist from 'plist';
import bplist from 'bplist-parser';
import { MatchedPair, SyncFileInfo } from './sync';

const execFileP = promisify(execFile);

export const TAG_XATTR = 'com.apple.metadata:_kMDItemUserTags';

export interface TagUpdate {
  destPath: string;
  relPath: string;      // source relPath, for display
  tags: string[];       // full merged tag list to write
  addedNames: string[]; // tag names being added, for display
}

const HEX_LINE = /^([0-9A-Fa-f]{2})( [0-9A-Fa-f]{2})*$/;

/** Parse `xattr -rpx <attr> <root>` stdout: `<path>: ` header lines followed by hex value lines. */
export function parseXattrDump(stdout: string): Map<string, Buffer> {
  const result = new Map<string, Buffer>();
  let current: string | null = null;
  let hex = '';
  const flush = () => {
    if (current && hex) result.set(current, Buffer.from(hex, 'hex'));
    current = null;
    hex = '';
  };
  for (const rawLine of stdout.split('\n')) {
    const line = rawLine.trimEnd();
    if (current && HEX_LINE.test(line)) {
      hex += line.replace(/ /g, '');
    } else if (line.endsWith(':')) {
      flush();
      current = line.slice(0, -1);
    }
  }
  flush();
  return result;
}

/** Decode a _kMDItemUserTags value: binary plist (Finder) or XML plist (written by us). */
export function decodeTags(data: Buffer): string[] {
  const parsed = data.subarray(0, 8).toString('latin1') === 'bplist00'
    ? bplist.parseBuffer(data)[0]
    : plist.parse(data.toString('utf8'));
  return Array.isArray(parsed) ? parsed.filter((t): t is string => typeof t === 'string') : [];
}

/** Tag identity is the name before the `\n<color>` suffix ("Red\n6" -> "Red"). */
export function tagName(tag: string): string {
  return tag.split('\n')[0];
}

/** Union merge: target tags first, then source tags whose name is new. Null = nothing to add. */
export function mergeTags(sourceTags: string[], targetTags: string[]): string[] | null {
  const existing = new Set(targetTags.map(tagName));
  const toAdd = sourceTags.filter((t) => !existing.has(tagName(t)));
  return toAdd.length ? [...targetTags, ...toAdd] : null;
}

/** Build a TagUpdate for one file, or null if the source has nothing new to add. */
function buildTagUpdate(
  destPath: string,
  relPath: string,
  source: string[] | undefined,
  target: string[],
): TagUpdate | null {
  if (!source || source.length === 0) return null;
  const merged = mergeTags(source, target);
  if (!merged) return null;
  const targetNames = new Set(target.map(tagName));
  return {
    destPath,
    relPath,
    tags: merged,
    addedNames: source.map(tagName).filter((n) => !targetNames.has(n)),
  };
}

export function computeTagUpdates(
  pairs: MatchedPair[],
  srcTags: Map<string, string[]>,
  destTags: Map<string, string[]>,
): TagUpdate[] {
  const updates: TagUpdate[] = [];
  for (const { src, dest } of pairs) {
    const update = buildTagUpdate(
      dest.fullPath,
      src.relPath,
      srcTags.get(src.fullPath),
      destTags.get(dest.fullPath) ?? [],
    );
    if (update) updates.push(update);
  }
  return updates;
}

/** Tag updates for files about to be copied: their dest copy starts untagged (copyFile drops
 *  xattrs), so merge source tags with whatever the dest path already had at scan time. */
export function computeCopyTagUpdates(
  files: SyncFileInfo[],
  srcTags: Map<string, string[]>,
  destTags: Map<string, string[]>,
  destRoot: string,
): TagUpdate[] {
  const updates: TagUpdate[] = [];
  for (const f of files) {
    const destPath = path.join(destRoot, f.relPath);
    const update = buildTagUpdate(
      destPath,
      f.relPath,
      srcTags.get(f.fullPath),
      destTags.get(destPath) ?? [],
    );
    if (update) updates.push(update);
  }
  return updates;
}

/** Read Finder tags for every file under root (absolute path). Two spawns per scan total.
 *  Files without tags produce stderr noise and exit code 1 — both ignored. */
export async function readTagsRecursive(root: string): Promise<Map<string, string[]>> {
  if (process.platform !== 'darwin') return new Map();
  const stdout = await new Promise<string>((resolve) => {
    // stderr is piped to 'ignore': files without the attr print noise there, and with
    // thousands of untagged files (typical for an SD card) an unconsumed pipe fills its
    // OS buffer and deadlocks the child process if we don't discard it.
    const child = spawn('xattr', ['-rpx', TAG_XATTR, root], { stdio: ['ignore', 'pipe', 'ignore'] });
    const chunks: Buffer[] = [];
    child.stdout.on('data', (c: Buffer) => chunks.push(c));
    child.on('close', () => resolve(Buffer.concat(chunks).toString('utf8')));
    child.on('error', () => resolve(''));
  });
  const map = new Map<string, string[]>();
  for (const [p, buf] of parseXattrDump(stdout)) {
    try {
      const tags = decodeTags(buf);
      if (tags.length) map.set(p, tags);
    } catch { /* unreadable plist — skip file */ }
  }
  return map;
}

/** Write the full tag list as an XML plist xattr (macOS reads XML and binary alike). */
export async function writeTags(filePath: string, tags: string[]): Promise<void> {
  if (process.platform !== 'darwin') return;
  const xml = plist.build(tags);
  await execFileP('xattr', ['-w', TAG_XATTR, xml, filePath]);
}
