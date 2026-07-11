import { describe, it, expect } from 'vitest';
import { diffFolders, SyncFileInfo } from './sync';

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
});
