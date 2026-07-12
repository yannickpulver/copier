import { describe, it, expect } from 'vitest';
import { resolveSyncTarget } from './syncTarget';

describe('resolveSyncTarget', () => {
  it('returns empty string when target is empty', () => {
    expect(resolveSyncTarget('/src/2024-trip', '', true)).toBe('');
    expect(resolveSyncTarget('/src/2024-trip', '', false)).toBe('');
  });

  it('returns target as-is when append is off', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/NAS/Photos', false))
      .toBe('/Volumes/NAS/Photos');
  });

  it('appends source basename when append is on', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/NAS/Photos', true))
      .toBe('/Volumes/NAS/Photos/2024-trip');
  });

  it('appends even when target basename matches source basename', () => {
    expect(resolveSyncTarget('/src/2024-trip', '/Volumes/SSD/2024-trip', true))
      .toBe('/Volumes/SSD/2024-trip/2024-trip');
  });

  it('strips trailing slashes before appending', () => {
    expect(resolveSyncTarget('/src/2024-trip/', '/Volumes/NAS/Photos/', true))
      .toBe('/Volumes/NAS/Photos/2024-trip');
  });

  it('returns target as-is when source is empty', () => {
    expect(resolveSyncTarget('', '/Volumes/NAS/Photos', true)).toBe('/Volumes/NAS/Photos');
  });
});
