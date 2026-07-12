function basename(p: string): string {
  return p.replace(/\/+$/, '').split('/').pop() ?? '';
}

/**
 * Resolve the effective sync target.
 * - exact: use targetPath as-is
 * - target basename === source basename: use targetPath as-is
 * - otherwise: sync into <targetPath>/<source basename>
 */
export function resolveSyncTarget(sourcePath: string, targetPath: string, exact: boolean): string {
  if (!targetPath) return '';
  if (exact || !sourcePath) return targetPath;
  const srcName = basename(sourcePath);
  if (basename(targetPath) === srcName) return targetPath;
  return `${targetPath.replace(/\/+$/, '')}/${srcName}`;
}
