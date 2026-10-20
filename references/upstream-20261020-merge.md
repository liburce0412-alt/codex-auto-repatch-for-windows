# Upstream integration and verification — 2026-10-20

## Sources and scope

- Upstream main: `4c318c42fb1d9faa09418f96a7eb53bf852f9fb4`, six commits beyond this fork's previous integration. PR #99 is now merged upstream; its implementation was already included here.
- Incorporated PRs [#101](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/101), [#102](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/102), and [#103](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/103): screenshot occlusion guidance, recoverable manual installation and optional Image-guided Assets discovery, and explicitly selected obsolete legacy-build cleanup.
- No open upstream PRs at review. Issues #93–#95 are unchanged. [Issue #100](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/100) proposes an experimental Win10 Sky 0.7.8 reconstruction; it is not integrated or claimed as validated on this Windows 11 host.

## Local decisions

- Preserve the fork's existing automatic source-version handoff and separate cleanup authorization. The new manual runner uses revisioned in-place installation and original-content recovery, and is not substituted into automatic deployment.
- Manual run/log roots stay below `%USERPROFILE%\Downloads\codex-msix-repack`. An explicitly passed `%USERPROFILE%\.codex\cwp-tmp` ASAR root avoids excessive path depth without redirecting TEMP, TMP, or npm caches. SDK and ASAR cache reuse remain available.
- Successful manual runs retain build, recovery and temporary artifacts. Cleanup remains a separate inventory-first command, with ownership, age, direct-child, active-process, reparse-point and installed-runtime checks. Legacy cleanup requires an exact path and explicitly selected data/temp roots.
- New launch/verification paths select one PowerShell 7 executable even when PATH has multiple matches.
- Keep local uncommitted launcher/physical-path overlays and `.skill-auto-update-disabled`. Do not change scheduled-task authorization, model routing, proxy settings, user environment, configuration or Chrome state.

## Runtime verification correction

The current package has two content-matching user-local runtime copies: a previously recovered copy and a later Desktop-materialized copy. Inventory already validates both executable contents against the installed package and checks resolved paths remain within the managed local runtime root. The later environment and Chrome v2 checks incorrectly required only the discovery-selected copy.

Environment verification now accepts a complete node/node_repl pair from any verified inventory bin. Chrome v2 verification similarly considers complete verified runtime pairs, combined with its existing accepted app-server paths. Missing, unverified or mixed-runtime pairs remain rejected. A healthy persisted recovered-runtime entry is retained byte-for-byte instead of rewritten. This fixes a verifier false positive; no runtime binaries or live settings were replaced.

## Verification performed

All final checks below passed:

- Recursive PowerShell parsing: 82 scripts in the isolated integration tree; `node --check scripts/test-bundled-marketplace-copy.cjs`; `git diff --check`.
- `test-model-experience-recoverable.ps1`: 92 checks.
- `test-cleanup-model-experience-artifacts.ps1`: 46 checks, including a real inventory-only child process.
- `test-user-cua-runtime-environment.ps1`: 8 cases covering current/recovered, mixed, unverified, missing, reversed and no-longer-allowed pairs.
- `test-chrome-native-host-v2-state.ps1`: existing schema/identity/state checks plus recovered-pair acceptance, byte-preserving update, and mixed/unverified-pair rejection.
- `test-bundled-marketplace-copy.cjs`: 23 cases.
- `test-computer-use-surface-patterns.ps1`: legacy 120-case and modern 304-case matrices, renamed gates/readiness, migration, fail-closed selection/scope and ASAR fallback.
- `test-custom-model-visibility-patterns.ps1`: 5,760 access cases and custom-model CSV/behavior checks.
- `test-browser-feature-hook-patterns.ps1`, `test-fast-mode-gate-patterns.ps1`, and `test-staged-package-selection.ps1`.
- `test-asar-cache-reuse.ps1`: 8 offline cases.
- `test-msix-safe-install.ps1`: 54 synthetic checks; no live deployment.
- `test-chrome-app-server-config.ps1`.
- `test-external-artifact-version.ps1`: 16 producer/version checks.
- Windows PowerShell 5.1 `test-asar-integrity.ps1 -CheckInstalledPackage`: all 15 cases, including read-only verification of installed `26.1013.4894.0`.
- Live PowerShell 7 `install-computer-use-local.ps1 -StrictVerifyOnly`: exit 0, browser/Chrome/native-host/runtime/trusted-root checks passed, official helper `list_windows` returned 4 windows.

Sandboxed Node spawning and an atomic fixture replacement initially failed with EPERM/access denied. The same scoped offline tests and read-only helper enumeration passed after running outside that restriction. These failures were not treated as package defects.

## Acceptance boundary

The installed package remains `26.1013.4894.0`, Developer/Ok. No Desktop repack, installation, restart, native capture/input, browser navigation, proxy repair, config/environment change or old-artifact cleanup was performed. The current Chrome custom-provider header hashes are outside known repair profiles; passing strict checks does not establish that authentication case is repaired. New manual installation and Image-guided Assets availability have fixture/source validation only, not a newly installed Desktop/UI acceptance result.

Integration is committed locally. Remote publication requires separate authorization.
