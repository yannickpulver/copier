import { describe, it, expect, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { diffFolders, syncFiles, SyncFileInfo } from './sync';

const f = (relPath: string, size: number, mtime = 0): SyncFileInfo => ({
  relPath,
  fullPath: `/root/${relPath}`,
  name: relPath.split('/').pop()!,
  size,
  mtime,
});

describe('diffFolders', () => {
  it('reports file as missing when no file with that name exists in dest', () => {
    const diff = diffFolders([f('a.jpg', 100)], [f('b.jpg', 100)]);
    expect(diff.missing.map((x) => x.name)).toEqual(['a.jpg']);
    expect(diff.different).toEqual([]);
    expect(diff.present).toEqual([]);
  });

  it('reports file as present when name+size match in a different subfolder', () => {
    const src = f('sub/a.jpg', 100);
    const dest = f('other/deep/a.jpg', 100);
    const diff = diffFolders([src], [dest]);
    expect(diff.present).toEqual([{ src, dest }]);
    expect(diff.missing).toEqual([]);
    expect(diff.different).toEqual([]);
  });

  it('reports file as present when source is nested and dest is flat', () => {
    const diff = diffFolders([f('x/y/z/a.jpg', 5)], [f('a.jpg', 5)]);
    expect(diff.present).toHaveLength(1);
  });

  it('ignores mtime: same name+size with newer source mtime is present', () => {
    const diff = diffFolders([f('a.jpg', 100, 999999999)], [f('a.jpg', 100, 0)]);
    expect(diff.present).toHaveLength(1);
    expect(diff.different).toEqual([]);
  });

  it('reports different when name matches but no candidate has same size', () => {
    const diff = diffFolders([f('a.jpg', 100)], [f('sub/a.jpg', 200)]);
    expect(diff.different).toHaveLength(1);
    expect(diff.different[0].destRelPath).toBe('sub/a.jpg');
    expect(diff.missing).toEqual([]);
    expect(diff.present).toEqual([]);
  });

  it('different at identical relPath does not set destRelPath', () => {
    const diff = diffFolders([f('a.jpg', 100)], [f('a.jpg', 200)]);
    expect(diff.different[0].destRelPath).toBeUndefined();
  });

  it('prefers exact relPath match among several same-name same-size candidates', () => {
    const src = f('sub/a.jpg', 100);
    const other = f('elsewhere/a.jpg', 100);
    const exact = f('sub/a.jpg', 100);
    const diff = diffFolders([src], [other, exact]);
    expect(diff.present[0].dest).toBe(exact);
  });

  it('two source files sharing a name: the size-matching one is present, the other is different and points at the match', () => {
    const a = f('A/a.jpg', 100);
    const b = f('B/a.jpg', 200);
    const dest = f('x/a.jpg', 100);
    const diff = diffFolders([a, b], [dest]);
    expect(diff.present).toEqual([{ src: a, dest }]);
    expect(diff.different).toHaveLength(1);
    expect(diff.different[0]).toEqual({ ...b, destRelPath: 'x/a.jpg' });
    expect(diff.missing).toEqual([]);
  });

  it('multi-candidate mixed sizes: matches the dest with the same size, not the first found', () => {
    const src = f('a.jpg', 100);
    const wrongSize = f('sub/a.jpg', 200);
    const rightSize = f('deep/a.jpg', 100);
    const diff = diffFolders([src], [wrongSize, rightSize]);
    expect(diff.present).toEqual([{ src, dest: rightSize }]);
    expect(diff.different).toEqual([]);
    expect(diff.missing).toEqual([]);
  });
});

describe('syncFiles', () => {
  let tmpDir: string;

  afterEach(() => {
    if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('always copies to the source relPath, never to destRelPath (which is display-only)', async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'copier-sync-test-'));
    const srcDir = path.join(tmpDir, 'src');
    const destRoot = path.join(tmpDir, 'dest');
    fs.mkdirSync(path.join(srcDir, 'B'), { recursive: true });
    fs.mkdirSync(path.join(destRoot, 'x'), { recursive: true });
    const srcFile = path.join(srcDir, 'B', 'a.jpg');
    fs.writeFileSync(srcFile, 'source content');
    // Simulate an existing candidate at the matched (but different) location that must not be touched.
    fs.writeFileSync(path.join(destRoot, 'x', 'a.jpg'), 'existing content');

    const file: SyncFileInfo = {
      relPath: 'B/a.jpg',
      fullPath: srcFile,
      name: 'a.jpg',
      size: fs.statSync(srcFile).size,
      mtime: 0,
      destRelPath: 'x/a.jpg',
    };

    const errors = await syncFiles([file], destRoot);
    expect(errors).toEqual([]);

    expect(fs.existsSync(path.join(destRoot, 'B', 'a.jpg'))).toBe(true);
    expect(fs.readFileSync(path.join(destRoot, 'B', 'a.jpg'), 'utf8')).toBe('source content');
    expect(fs.readFileSync(path.join(destRoot, 'x', 'a.jpg'), 'utf8')).toBe('existing content');
  });
});
