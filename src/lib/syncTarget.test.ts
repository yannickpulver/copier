import { describe, it, expect } from 'vitest';
import { resolveSyncTarget } from './syncTarget';

describe('resolveSyncTarget', () => {
  it('returns empty string when target is empty', () => {
    expect(resolveSyncTarget('/src/2024-trip', '', false)).toBe('');
    expect(resolveSyncTarget('/src/2024-trip', '', true)).toBe('');
  });

  it('returns target as-is when exact flag is set', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/SSD/2024-trip-final', true))
      .toBe('/Volumes/SSD/2024-trip-final');
  });

  it('returns target as-is when target basename matches source basename', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/SSD/Backup/2024-trip', false))
      .toBe('/Volumes/SSD/Backup/2024-trip');
  });

  it('appends source basename when names differ and exact is off', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/NAS/Photos', false))
      .toBe('/Volumes/NAS/Photos/2024-trip');
  });

  it('returns target as-is when source is empty', () => {
    expect(resolveSyncTarget('', '/Volumes/NAS/Photos', false)).toBe('/Volumes/NAS/Photos');
  });

  it('ignores trailing slashes when comparing basenames', () => {
    expect(resolveSyncTarget('/src/2024-trip/', '/Volumes/SSD/2024-trip/', false))
      .toBe('/Volumes/SSD/2024-trip/');
  });
});
