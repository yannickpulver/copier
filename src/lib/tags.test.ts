import { describe, it, expect } from 'vitest';
import { parseXattrDump, decodeTags, tagName, mergeTags, computeTagUpdates } from './tags';
import { SyncFileInfo } from './sync';

// Real binary plist for ["Red\n6", "Holiday"] (generated with plutil -convert binary1)
const BPLIST_HEX =
  '62706c6973743030a20102555265640a3657486f6c69646179080b11000000000000010100000000000000030000000000000000' +
  '0000000000000019';

// XML plist for ["Blue\n4"] as written by xattr -w
const XML_PLIST = '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Blue\n4</string></array></plist>';

/** Format a buffer the way `xattr -rpx` prints values: 16 uppercase hex pairs per line, trailing space. */
function hexDump(buf: Buffer): string {
  const pairs = buf.toString('hex').toUpperCase().match(/.{2}/g)!;
  const lines: string[] = [];
  for (let i = 0; i < pairs.length; i += 16) {
    lines.push(pairs.slice(i, i + 16).join(' ') + ' ');
  }
  return lines.join('\n');
}

describe('parseXattrDump', () => {
  it('parses multiple file entries with hex values', () => {
    const bufA = Buffer.from(BPLIST_HEX, 'hex');
    const bufB = Buffer.from(XML_PLIST, 'utf8');
    const stdout = `/Volumes/NAS/photos/a.jpg: \n${hexDump(bufA)}\n/Volumes/NAS/photos/sub/b file.jpg: \n${hexDump(bufB)}\n`;
    const map = parseXattrDump(stdout);
    expect(map.size).toBe(2);
    expect(map.get('/Volumes/NAS/photos/a.jpg')!.equals(bufA)).toBe(true);
    expect(map.get('/Volumes/NAS/photos/sub/b file.jpg')!.equals(bufB)).toBe(true);
  });

  it('returns empty map for empty output', () => {
    expect(parseXattrDump('').size).toBe(0);
  });
});

describe('decodeTags', () => {
  it('decodes binary plists (Finder-written)', () => {
    expect(decodeTags(Buffer.from(BPLIST_HEX, 'hex'))).toEqual(['Red\n6', 'Holiday']);
  });

  it('decodes XML plists (written by this app)', () => {
    expect(decodeTags(Buffer.from(XML_PLIST, 'utf8'))).toEqual(['Blue\n4']);
  });
});

describe('tagName', () => {
  it('strips the color suffix', () => {
    expect(tagName('Red\n6')).toBe('Red');
    expect(tagName('Holiday')).toBe('Holiday');
  });
});

describe('mergeTags', () => {
  it('adds source tags missing from target, keeping target tags first', () => {
    expect(mergeTags(['Red\n6', 'Trip'], ['Blue\n4'])).toEqual(['Blue\n4', 'Red\n6', 'Trip']);
  });

  it('returns null when target already has all source tag names', () => {
    expect(mergeTags(['Red'], ['Red\n6', 'Other'])).toBeNull();
  });

  it('returns null when source has no tags', () => {
    expect(mergeTags([], ['Blue\n4'])).toBeNull();
  });

  it('matches by name ignoring color suffix', () => {
    expect(mergeTags(['Red\n6'], ['Red'])).toBeNull();
  });
});

describe('computeTagUpdates', () => {
  const file = (fullPath: string): SyncFileInfo => ({
    relPath: fullPath.split('/').pop()!,
    fullPath,
    name: fullPath.split('/').pop()!,
    size: 1,
    mtime: 0,
  });

  it('produces updates only for pairs where source has tags the target lacks', () => {
    const pairs = [
      { src: file('/src/a.jpg'), dest: file('/dst/a.jpg') }, // src tagged, dst untagged -> update
      { src: file('/src/b.jpg'), dest: file('/dst/b.jpg') }, // both tagged same -> no update
      { src: file('/src/c.jpg'), dest: file('/dst/c.jpg') }, // src untagged, dst tagged -> no update (keep dst tags)
    ];
    const srcTags = new Map([
      ['/src/a.jpg', ['Red\n6']],
      ['/src/b.jpg', ['Holiday']],
    ]);
    const destTags = new Map([
      ['/dst/b.jpg', ['Holiday']],
      ['/dst/c.jpg', ['Keep']],
    ]);
    const updates = computeTagUpdates(pairs, srcTags, destTags);
    expect(updates).toEqual([
      { destPath: '/dst/a.jpg', relPath: 'a.jpg', tags: ['Red\n6'], addedNames: ['Red'] },
    ]);
  });

  it('merges into existing target tags', () => {
    const pairs = [{ src: file('/src/a.jpg'), dest: file('/dst/a.jpg') }];
    const updates = computeTagUpdates(
      pairs,
      new Map([['/src/a.jpg', ['Red\n6', 'Trip']]]),
      new Map([['/dst/a.jpg', ['Trip', 'Own']]]),
    );
    expect(updates[0].tags).toEqual(['Trip', 'Own', 'Red\n6']);
    expect(updates[0].addedNames).toEqual(['Red']);
  });
});
