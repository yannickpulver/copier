import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import plist from 'plist';
import bplist from 'bplist-parser';
import { MatchedPair } from './sync';

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

export function computeTagUpdates(
  pairs: MatchedPair[],
  srcTags: Map<string, string[]>,
  destTags: Map<string, string[]>,
): TagUpdate[] {
  const updates: TagUpdate[] = [];
  for (const { src, dest } of pairs) {
    const source = srcTags.get(src.fullPath);
    if (!source || source.length === 0) continue;
    const target = destTags.get(dest.fullPath) ?? [];
    const merged = mergeTags(source, target);
    if (!merged) continue;
    const targetNames = new Set(target.map(tagName));
    updates.push({
      destPath: dest.fullPath,
      relPath: src.relPath,
      tags: merged,
      addedNames: source.map(tagName).filter((n) => !targetNames.has(n)),
    });
  }
  return updates;
}

/** Read Finder tags for every file under root (absolute path). Two spawns per scan total.
 *  Files without tags produce stderr noise and exit code 1 — both ignored. */
export async function readTagsRecursive(root: string): Promise<Map<string, string[]>> {
  if (process.platform !== 'darwin') return new Map();
  const stdout = await new Promise<string>((resolve) => {
    const child = spawn('xattr', ['-rpx', TAG_XATTR, root]);
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
