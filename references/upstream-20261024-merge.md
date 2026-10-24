# Upstream review: 2026-10-24

## Sources and integration

- Fork main before this work: `91ad3f932afc923cad24a39ca3d72763f7eb92e4`.
- Local startup fix: `6fc4b15` corrects launcher output contamination, main-process selection, and the managed CLI override before Desktop starts. The six local automation scripts were deployed without restarting Desktop.
- Upstream main: `d08b285e59871108b5efe5e3c58f28cf5ad4f019` ([PR #106](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/106)). Merged helper profiles, Store fallback profiles, and resource-boundary recovery protection. Kept the fork's existing helper profiles, exact-artifact safeguards, and explicit-only synchronization policy.
- Open [PR #107](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/107), pinned to `09ef59e36261c790a17187591c1024d5fd8208fd`: integrated native Windows CUA recognition, Goal translation-bundle filtering, native Power target discovery, and the separately guarded `un`/`dn` Store Offers profile.
- Open [PR #108](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/108), pinned to `642154e9688c94d6daedd33c53cfc41909624156`: reused its precise `app-primary-*`, `ModelPickerPowerSlider`, and `canRenderPowerPickerSurface` discovery witnesses. CUA behavior follows #107 instead: the actual `Iie` function reconciles legacy skill directories, while the native surface already includes Windows and the installed/enabled/available plugin guard. Preserve both native conditions without a rewrite. Retained the fork's extra malformed/mixed-native negative tests.
- No duplicate upstream PR: shared compatibility is already covered by those open PRs. The startup automation directory exists only in this fork.

## Open issues reviewed

- [#104](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/104): upstream now includes an exact A8533C3D helper profile. Full-hash and platform checks still decide applicability; an issue title/prefix is not validation.
- [#100](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/100), [#94](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/94): Windows 10 helper reports outside the current Windows 11/current-helper case. No unreviewed binary workaround was applied.
- [#93](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/93): existing 0.7.6 profiles retained.
- [#95](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/95): Windows 10 tray report remains open, without a new verified fix in the reviewed changes.

## Verification

- `automation/tests/test-standing-startup.ps1`: passed on both the local overlay and portable source. Reproduced the original missing `ProcessId` error before fixing it. Covers noisy launcher output, renderer rejection, managed version updates, custom overrides, and failed verification/readback.
- `automation/tests/test-update-safety.ps1` and `test-runtime-recovery.ps1`: passed for the startup repair; upstream does not modify their inputs.
- `scripts/test-computer-use-surface-patterns.ps1`: passed legacy and modern behavior, renamed locals, migration, native Windows behavior (48 cases), negative cases, and ASAR runner fallback.
- `scripts/test-native-layout-discovery.ps1`: passed against the actual 26.1021 extracted JS set; target discovery took 39.15 seconds, and the native Power slider remained unchanged.
- The final embedded surface patcher returned `already-open-native-windows` on actual `main-Dk6YMjS1.js`, with byte-identical contents.
- `scripts/test-windows-store-update-fallback.cjs`: passed against actual `bootstrap-DbqNeN1Q.js`, including the shipped `un`/`dn` comparator, original NoUpdates failure, manual/background/cached fallback, wrong identity/publisher, missing feed, and mixed-profile rejection.
- `scripts/test-msix-safe-install.ps1`: 58 checks passed, including resource-boundary preservation without another deployment.
- `scripts/test-computer-use-helper-win10-patch.ps1`: two locally available exact 0.7.12 profiles passed on disposable copies, including candidate hashes, rollback, and the Windows 11 install guard. Other newly added profiles were not executed without matching source bytes.
- `scripts/test-asar-integrity.ps1 -CheckInstalledPackage`: 15 cases passed under Windows PowerShell 5.1, including the current installed Store package's read-only integrity check.
- `scripts/test-staged-package-selection.ps1`: passed. `scripts/test-custom-model-visibility-patterns.ps1`: passed, including 5,760 access-program behavior combinations.
- The existing Windows SDK MakeAppx help confirms `/ml` is a supported byte-based memory limit, matching upstream's new packing argument.
- PowerShell parsing, changed CommonJS syntax, and `git diff --check`: passed.

## Acceptance boundary

The running app remains official Store `26.1021.2667.0`, using its matching CLI `0.164.0-alpha.11.1`. No application restart or package installation occurred in this review. The earlier default-scope DryRun passed; final integration additionally verified native CUA preservation and full target discovery against the actual bundle. This is source/compatibility validation, not signed-package installation acceptance. Native screenshots/input, Windows 10 device behavior, and a future-version download were not exercised. Temporary build and test copies are disposable; retain the small logs and this record.
