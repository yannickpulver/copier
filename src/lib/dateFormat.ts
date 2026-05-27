export const DEFAULT_DATE_FORMAT = 'YYYY.MM.DD';

/** Format a 'YYYY-MM-DD' date string using tokens YYYY, YY, MM, DD. */
export function formatFolderDate(ymd: string, format: string = DEFAULT_DATE_FORMAT): string {
  const [y = '', m = '', d = ''] = ymd.split('-');
  return format
    .replace(/YYYY/g, y)
    .replace(/YY/g, y.slice(2))
    .replace(/MM/g, m)
    .replace(/DD/g, d);
}
