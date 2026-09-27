# Upstream main merge: 2026-09-27

Merged upstream `32530552de5a329d80a38085f4052863aef63da5` into fork
`b6a448a93aecf5a4a153b755ff0ef58cf098ad4c`. GitHub's commits API confirmed the
upstream head after a fetch encountered a TLS handshake error. This includes
the 20 upstream-only commits reviewed before the merge. Open PRs #74–#76 are
not included.

## Result

- Add Desktop 26.924.2738 Fast Mode matching for `personalAccessToken`, with
  the upstream behavioral fixtures, and Chrome 26.924.22138's exact source hash.
- Add upstream's two exact-hash sky 0.7.1 Windows 10 helper profiles.
- Retain the previously integrated #68–#73 implementations, including the
  fork's bounded receiver matcher and alternate native-host contract witness.
- Preserve the entire `automation/` tree, scoped local plugin installer,
  exact-source-version artifact contract and disabled automatic GitHub sync.
- Keep the fork's installation and recovery documentation, incorporate upstream
  repair/resume and optional prompt guidance, and retain the upstream logo.
- Document the observed copied-CLI incomplete-local-package failure and the
  current-user-only certificate trust failure. Neither is fixed by this merge.

## Verification

All 18 selected regression suites passed:

| Area | Suites |
| --- | --- |
| Desktop gates | `test-fast-mode-gate-patterns.ps1` (20 behavioral cases), `test-desktop-feature-slot-patterns.ps1`, `test-computer-use-surface-patterns.ps1`, `test-browser-sidebar-discovery.ps1` (18 checks), `test-browser-sidebar-gate-patterns.ps1`, `test-custom-model-visibility-patterns.ps1` |
| Packaging | `test-msix-payload.ps1` (8 cases), `test-msix-safe-install.ps1` (51 checks), `test-external-artifact-version.ps1` (16 checks), `test-staged-package-selection.ps1`, `test-asar-integrity.ps1 -CheckInstalledPackage` |
| Automation | `test-update-safety.ps1`, `test-update-progress.ps1`, `test-superseded-watcher.ps1` (6 cases) |
| Chrome | `test-chrome-browser-client-trust-contract.ps1`, `test-chrome-native-host-origin-drift.ps1`, `test-chrome-custom-provider-headers.cjs` (48 checks), `test-chrome-header-cache-scope.ps1` (26 checks) |

Recursive parsing passed for 73 PowerShell files; Node syntax checks passed for
both changed CommonJS files. `git diff --check` passed. The automatic update
scripts, scoped plugin installer and `.skill-auto-update-disabled` are unchanged
from the fork baseline.

The native-host origin fixture requires `Add-Type -OutputType ConsoleApplication`,
which PowerShell 7 does not support. It passed under Windows PowerShell 5.1.
The Chrome cache fixture initially hit WindowsApps EFS attribute propagation;
it passed using a byte-copied source with the identical SHA-256. Production
source files and live configuration were not changed by these workarounds.

Chrome behavioral tests used the available original 26.924.20706 service.
The new 26.924.22138 source and the two exact original Win10 helper binaries
were unavailable locally; their new profiles were inspected and parsed but
not exercised against those binaries. No Desktop installation, restart,
automation redeployment or live UI acceptance was performed.
