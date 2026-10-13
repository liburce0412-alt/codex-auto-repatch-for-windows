# Upstream merge: 2026-10-13

Merged upstream `43ac02c` into the fork based on `46449a2`. Before merging,
the fork was 45 commits ahead and three commits behind upstream.

| Commit | Change |
| --- | --- |
| `484ac5a` | Distinguish Desktop 26.1007 browser policy failures |
| `465f8c6` | Merge upstream PR #96 with those diagnostic notes |
| `43ac02c` | Support 26.1007 service-tier access and optional plugin discovery |

## Integration

- Adopt the 26.1007 Fast/Ultrafast access-object patterns while preserving
  requirements fetching, caching, independent tier flags and loading behavior.
- Include optional `pullRequests` and `unifiedComputerUse` discovery patterns.
  These descriptor changes do not automatically install plugins or change
  unrelated engine flags.
- Resolve the single patch-script conflict by retaining both the fork's
  custom-model/browser target finders and upstream's service-tier predicates.
  The two fork finder bodies are unchanged and each appears once.
- Retain machine-specific storage, launcher and automation overlays outside
  the published merge. Desktop repatching continues to use its established
  C: workflow.
- Update both READMEs for this merge and the existing metadata-based cleanup
  optimization. Legacy manifests and security/recovery contracts retain their
  required integrity checks.

## Validation

All checks below passed under PowerShell 7. Tests used isolated temporary
fixtures; installed package input was read-only.

- PowerShell parsing: all 57 scripts under `scripts`; changed CommonJS syntax;
  staged and unstaged `git diff --check`.
- `test-service-tier-access-patterns.ps1`: 479 checks, including the actual
  installed Desktop `26.1007.2314.0` app-initial asset, idempotence and full-file
  change isolation.
- `test-fast-mode-gate-patterns.ps1`: 60 behavior cases.
- `test-bundled-marketplace-copy.cjs`: 18 cases.
- `test-custom-model-visibility-patterns.ps1`: 5,760 access-program
  combinations and CSV behavior checks.
- `test-computer-use-surface-patterns.ps1`: legacy 120-case and current
  304-case matrices, renamed-gate migration, fail-closed guards and ASAR
  fallback checks.
- Browser feature-hook regression; browser sidebar discovery: 18 checks;
  staged-package selection; ASAR integrity synthetic regression: 14 cases.

This is source compatibility and regression evidence. No Desktop repack,
installation, restart, live browser/native UI or remote API acceptance test
was performed. No Win10-only helper patch was applied to this Windows 11 host.

## PR and issue review

[PR #96](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/96)
is merged and included above. There were no open upstream PRs at review time.
Its browser-policy diagnostics do not establish a new runtime fix or local
browser acceptance.

Three upstream issues remained open at review time:

| Issue | Finding |
| --- | --- |
| [#93](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/93) | Win10 Sky screenshot timeout and missing coordinate geometry. The `F78948E6` and `63C98C4D` exact helper profiles are already included; Win10 capture/input acceptance remains unresolved. |
| [#94](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/94) | Win10 helper `58FFF5E2` is still unsupported by the merged profiles. A contributor reports a successful experimental change on one host, but no formal profile fix or open PR is available. |
| [#95](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/95) | Missing tray icon on Win10 22H2 with Codex 26.1007.21434; no comments or confirmed fix. No local Windows 11 reproduction was established. |

These reports are tracked without treating contributor observations as new
local acceptance or applying experimental fixes to an unrelated host.
