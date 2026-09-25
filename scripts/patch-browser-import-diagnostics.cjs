const fs = require('node:fs');

const marker = 'CODEX_BROWSER_IMPORT_DIAGNOSTICS_V1';
const start = 'async importBrowserProfile(e){';
const end = '}async listImportableBrowserProfiles(){';
const prefix = `/*${marker}*/try{`;
const suffix = '}catch(importError){try{this.logger.error(`Browser profile import exception`,{safe:{errorName:importError instanceof Error?importError.name:typeof importError},sensitive:{error:importError}})}catch{}throw importError}';

function patchSource(source) {
  const count = source.split(start).length - 1;
  const markers = source.split(marker).length - 1;
  if (!count && !markers && !source.includes('browserProfileImporter')) {
    return { source, status: 'not-applicable' };
  }
  if (count !== 1) throw new Error('browser import method must occur exactly once');
  const begin = source.indexOf(start) + start.length;
  const finish = source.indexOf(end, begin);
  if (finish < begin) throw new Error('browser import method boundary is unsupported');
  let body = source.slice(begin, finish);
  if (markers) {
    if (markers !== 1 || !body.startsWith(prefix) || !body.endsWith(suffix)) {
      throw new Error('incomplete browser import diagnostics patch');
    }
    body = body.slice(prefix.length, -suffix.length);
  }
  if (!body.startsWith('if(!await this.isImportAllowed())') ||
      !body.includes('this.#e.browserProfileImporter.list()') ||
      !body.includes('this.#e.browserProfileImporter.import(t)') ||
      !source.includes('logger=') || !source.includes('browser-profile-import')) {
    throw new Error('browser import diagnostics method shape is unsupported');
  }
  if (markers) return { source, status: 'already-patched' };
  return {
    source: source.slice(0, begin) + prefix + body + suffix + source.slice(finish),
    status: 'patched',
  };
}

module.exports = { patchSource };
if (require.main === module) {
  try {
    const file = process.argv[2];
    const before = fs.readFileSync(file, 'utf8');
    const result = patchSource(before);
    if (result.source !== before) fs.writeFileSync(file, result.source);
    process.stdout.write(result.status);
  } catch (error) {
    process.stderr.write(error.message + '\n');
    process.exitCode = 2;
  }
}
