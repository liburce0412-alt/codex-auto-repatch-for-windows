const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const MARKER = 'CODEX_WINDOWS_STORE_FALLBACK_V1';
const ORIGINAL = 'if(S7().info(`Windows Store package update check completed`,{safe:{canSilentlyDownload:i.canSilentlyDownload,completed:i.completed,hasUpdate:i.hasUpdate,overallState:i.overallState},sensitive:{}}),!i.hasUpdate)return this.setUpdateReady(!1),this.setUpdateLifecycleState(`idle`),{decision:{kind:`handled`},outcome:`up-to-date`};';
const REPLACEMENT = 'if(S7().info(`Windows Store package update check completed`,{safe:{canSilentlyDownload:i.canSilentlyDownload,completed:i.completed,hasUpdate:i.hasUpdate,overallState:i.overallState},sensitive:{}}),!i.hasUpdate){this.setUpdateReady(!1),this.setUpdateLifecycleState(`idle`);let codexManifestHasUpdate=n!=null&&f7(this.options.buildVersion)&&d7(n.buildVersion,this.options.buildVersion)>0;return e&&codexManifestHasUpdate?{decision:{kind:`fallback`,reason:`store-no-update-for-newer-manifest`},outcome:null}:{decision:{kind:`handled`},outcome:codexManifestHasUpdate?`update-available-in-store`:`up-to-date`}}/*CODEX_WINDOWS_STORE_FALLBACK_V1*/';

function patchText(source) {
  if (!source.includes('windows-store-updater') || !source.includes('msixFallbackUpdater') ||
      !source.includes('checkForUpdatesWithFallbackDecision') || !source.includes('async downloadUpdatePackage(')) {
    throw new Error('Unsupported Windows updater layout; no files changed');
  }
  const count = fragment => source.split(fragment).length - 1;
  if (source.includes(MARKER)) {
    if (count(MARKER) !== 1 || count(REPLACEMENT) !== 1 || count(ORIGINAL) !== 0) {
      throw new Error('Partial or ambiguous Windows updater patch; no files changed');
    }
    return {state: 'already-patched', source};
  }
  if (count(ORIGINAL) !== 1) throw new Error('Expected exactly one Windows Store NoUpdates branch; no files changed');
  return {state: 'patched', source: source.replace(ORIGINAL, REPLACEMENT)};
}

if (require.main === module) {
  try {
    const root = path.resolve(process.argv[2]);
    if (/(?:^|[\\/])WindowsApps(?:[\\/]|$)/i.test(root)) throw new Error('Refusing WindowsApps writes');
    const candidates = fs.readdirSync(root).filter(name => name.endsWith('.js')).map(name => path.join(root, name))
      .filter(file => fs.readFileSync(file, 'utf8').includes('windows-store-updater'));
    if (candidates.length !== 1) throw new Error(`Expected one Windows updater asset, found ${candidates.length}`);
    const file = candidates[0];
    const result = patchText(fs.readFileSync(file, 'utf8'));
    const syntax = spawnSync(process.execPath, ['--check', '--input-type=commonjs'], {input: result.source, encoding: 'utf8'});
    if (syntax.status !== 0) throw new Error(syntax.stderr || 'Windows updater syntax validation failed');
    if (result.state === 'patched') fs.writeFileSync(file, result.source);
    console.log(result.state);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {patchText, ORIGINAL, REPLACEMENT, MARKER};
