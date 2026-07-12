function basename(p: string): string {
  return p.replace(/\/+$/, '').split('/').pop() ?? '';
}

/**
 * Resolve the effective sync target.
 * - append: sync into <targetPath>/<source basename>
 * - otherwise: use targetPath as-is
 */
export function resolveSyncTarget(sourcePath: string, targetPath: string, append: boolean): string {
  if (!targetPath) return '';
  if (!append || !sourcePath) return targetPath;
  return `${targetPath.replace(/\/+$/, '')}/${basename(sourcePath)}`;
}
