const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {createHash} = require('node:crypto');
const {spawnSync} = require('node:child_process');
const os = require('node:os');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function validatePlatform(platform, build, productType) {
  assert(platform === 'win32' && Number.isInteger(build) && build >= 10240 && build < 22000 && productType === 1,
    'Capture diagnostics require a Windows 10 client guest/test machine');
}

function validateTarget(state, config, now = Date.now()) {
  assert.equal(state.token, config.token, 'Unexpected test window');
  assert.equal(state.processId, config.targetProcessId, 'Test window process changed');
  assert(Number.isSafeInteger(state.windowId) && state.windowId > 0, 'Missing test window handle');
  assert(Number.isFinite(state.timestamp) && now >= state.timestamp && now - state.timestamp < 2000,
    'Test window state expired; stop');
  assert.equal(state.foreground, true, 'Test window lost focus; stop');
  return state;
}

function selectWindow(windows, state, token) {
  const matches = windows.filter(window => window.id === state.windowId &&
    window.title === `Codex Win10 Capture Test ${token}` && typeof window.app === 'string' && window.app.length);
  assert.equal(matches.length, 1, 'Test window is unavailable or ambiguous; stop');
  return matches[0];
}

function approveTestWindow(request, allowedApp) {
  assert.equal(request.meta?.connector_id, 'computer-use', 'Unexpected approval connector');
  assert.equal(request.meta?.tool_params?.app, allowedApp, 'Approval is outside the test window');
  return {action: 'accept'};
}

function decodeScreenshot(screenshot) {
  const match = /^data:image\/(jpeg|png);base64,([A-Za-z0-9+/]+={0,2})$/.exec(screenshot.url);
  assert(match && match[2].length % 4 === 0, 'Expected an inline JPEG/PNG screenshot');
  const bytes = Buffer.from(match[2], 'base64');
  const magic = match[1] === 'jpeg' ? 'ffd8ff' : '89504e470d0a1a0a';
  assert(bytes.subarray(0, magic.length / 2).toString('hex') === magic, 'Invalid image header');
  return {bytes, extension: match[1] === 'jpeg' ? 'jpg' : 'png'};
}

async function run(config, phase) {
  assert(['original', 'patched'].includes(phase), 'Unexpected phase');
  const product = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    '(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType'],
  {encoding: 'utf8', windowsHide: true, timeout: 10000});
  validatePlatform(process.platform, Number(os.release().split('.')[2]),
    product.status === 0 ? Number(product.stdout.trim()) : NaN);
  const root = path.resolve(config.runRoot);
  process.env.CODEX_HOME = path.join(root, `codex-home-${phase}`);
  fs.mkdirSync(process.env.CODEX_HOME, {recursive: true});
  const statePath = path.join(root, 'target-state.json');
  const closedPath = path.join(root, 'closed.flag');
  function state() {
    assert(!fs.existsSync(closedPath), 'Test window was closed; stop');
    return validateTarget(JSON.parse(fs.readFileSync(statePath, 'utf8')), config);
  }
  const internal = path.join(config.skyRoot, 'dist/project/cua/sky_js/src/targets/windows/internal');
  const {WindowsHelperTransport} = await import(pathToFileURL(path.join(internal, 'helper_transport.js')).href);
  const {WindowsComputerUseClientBase} = await import(pathToFileURL(path.join(internal, 'computer_use_client_base.js')).href);
  const transport = new WindowsHelperTransport({helperCommand: config.helperPath,
    helperArgs: ['--parent-pid', String(process.pid)], timeoutMs: 15000});
  let allowedApp;
  const metadata = {session_id: config.token, turn_id: `${phase}-${config.token}`};
  const client = new WindowsComputerUseClientBase({transport: {
    close: () => transport.close(),
    request: (method, params) => {
      if (method !== 'list_windows') state();
      if (params.window) assert.equal(params.window.id, state().windowId, 'Unexpected input target');
      return transport.request(method, params, {codexTurnMetadata: metadata,
        createElicitation: async request => approveTestWindow(request, allowedApp)});
    }
  }});
  const report = {phase, frames: [], resourceSamples: [], capturePassed: false,
    input: 'not requested', visualInspection: 'pending', endToEndValidatedDesktopVersion: null};
  function resources(label) {
    const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      '$ErrorActionPreference="Stop"; @(Get-Process -Name codex-computer-use -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $env:CODEX_WIN10_DIAG_HELPER } | ForEach-Object { [pscustomobject]@{ pid=$_.Id; threads=$_.Threads.Count; handles=$_.HandleCount; workingSet=$_.WorkingSet64 } }) | ConvertTo-Json -Compress'],
    {encoding: 'utf8', windowsHide: true, timeout: 10000,
      env: {...process.env, CODEX_WIN10_DIAG_HELPER: config.helperPath}});
    report.resourceSamples.push({label, available: result.status === 0,
      processes: result.status === 0 ? JSON.parse(result.stdout.trim() || '[]') : null});
  }
  try {
    const windows = await client.list_windows();
    const window = selectWindow(windows, state(), config.token);
    allowedApp = window.app;
    report.windowCount = windows.length;
    const accessibility = await client.get_window_state({window, include_text: true, include_screenshot: false});
    report.accessibilityContainsTarget = accessibility.accessibility?.tree.includes('Codex Win10 Capture Test') === true;
    assert(report.accessibilityContainsTarget, 'Accessibility does not identify the test target');
    async function capture(kind) {
      const started = performance.now();
      const captured = await client.get_window_state({window, include_screenshot: true, include_text: false});
      const elapsedMs = Math.round(performance.now() - started);
      state();
      assert.equal(captured.screenshots.length, 1, 'Expected one bounded test-window screenshot');
      const screenshot = captured.screenshots[0];
      const {bytes, extension} = decodeScreenshot(screenshot);
      const file = `${phase}-${kind}-${report.frames.length}.${extension}`;
      fs.writeFileSync(path.join(root, file), bytes);
      report.frames.push({kind, file, elapsedMs, bytes: bytes.length,
        sha256: createHash('sha256').update(bytes).digest('hex').toUpperCase()});
      return screenshot;
    }
    report.captureAttempted = true;
    await capture('cold');
    if (phase === 'patched') {
      resources('warm');
      for (let index = 0; index < 20; index++) await capture('static');
      await delay(2000);
      resources('after-static');
      fs.writeFileSync(path.join(root, 'animate.flag'), '');
      for (let index = 0; index < 4; index++) { await delay(2000); await capture('dynamic'); }
      fs.rmSync(path.join(root, 'animate.flag'));
      const dynamicHashes = report.frames.filter(frame => frame.kind === 'dynamic').map(frame => frame.sha256);
      report.distinctDynamicFrames = new Set(dynamicHashes).size;
      assert(report.distinctDynamicFrames === 4, 'Dynamic frames did not all change');
      resources('after-dynamic');
      if (config.testInput) {
        const current = state();
        const screenshot = await capture('input');
        assert(screenshot.width === current.width && screenshot.height === current.height,
          'Input test requires a 1:1 screenshot/window coordinate scale');
        await client.click({window, screenshotId: screenshot.id, ...current.button});
        await delay(200);
        assert.equal(state().clicks, current.clicks + 1, 'Coordinate click did not reach the test button');
        const textboxScreenshot = await capture('input');
        await client.click({window, screenshotId: textboxScreenshot.id, ...state().textbox});
        await client.type_text({window, text: `CUA-${config.token}`});
        await delay(200);
        assert.equal(state().input, `CUA-${config.token}`, 'Text input did not reach the test textbox');
        report.input = 'passed';
      }
    }
    report.capturePassed = true;
  } catch (error) {
    report.error = String(error.message).replace(/[A-Z]:[\\/][^\r\n"']*/gi, '<local-path>');
    report.stopped = /Escape|stopped by the user|test window.*(?:closed|focus|expired|unavailable|ambiguous)/i.test(error.message);
    report.expectedBaselineFailure = phase === 'original' && report.captureAttempted === true && !report.stopped &&
      /FrameArrived timed out|window capture timed out|SetIsBorderRequired|0x80004002|timed out waiting on channel/i.test(error.message);
  } finally {
    await client.close();
    fs.writeFileSync(path.join(root, `${phase}-result.json`), JSON.stringify(report, null, 2));
  }
  return report;
}

module.exports = {validatePlatform, validateTarget, selectWindow, approveTestWindow, decodeScreenshot};
if (require.main === module) {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  run(config, process.argv[3]).then(report => {
    console.log(JSON.stringify({phase: report.phase, capturePassed: report.capturePassed, stopped: report.stopped ?? false}));
    process.exitCode = report.stopped || (!report.capturePassed && !report.expectedBaselineFailure) ? 1 : 0;
  }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
