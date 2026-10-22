# Upstream merge — 2026-10-22

Merged upstream `3d3319c7cc5b7876ea7bf1e985daaf8ae856a442` (PR #105) onto fork `d39688ed98de7004c31570a085060e32f22a60ce`.

## Scope and conflict resolutions

- Accept upstream Dot browser payload discovery, rewriting and repeat-run coverage, including Dot-only layouts. Preserve the fork's scoped Browser/Computer Use finder.
- Add repair deployment checkpoints and the read-only status query. PID, start time, session and user identity distinguish a live installer from PID reuse; registration alone is not acceptance. Superseding packages do not inherit historical acceptance.
- Keep the fork's C: build and short ASAR paths, existing SDK reuse, PowerShell 7 launcher and unchanged TEMP/TMP/npm environment.
- As authorized on 2026-10-22, the manual recoverable installer removes only the current build, recovery package and temporary ASAR tree after acceptance is durably saved. `-KeepArtifacts` is forwarded through the launcher. Logs and state remain; deployment/checkpoint failure retains artifacts. Cleanup failure is separate from installation failure.
- The automatic same-version watcher and its separately requested historical cleanup remain unchanged. This source update does not deploy automation scripts, reinstall Desktop or change startup/proxy settings.

## Upstream review

No open pull requests remained at this check. Open issues were #93, #94, #95, #100 and #104. The new #104 reports Windows 10 sky 0.7.12 capture failure without a released fix; #100 proposes a Windows 10 binary reconstruction with different certificate-overlay/length handling. Neither is an accepted upstream patch or applicable evidence for this Windows 11 host, so no binary profile was invented or applied. The browser fix already exists in upstream PR #105, so no duplicate PR was created.

## Verification

Passed isolated regressions:

- `test-model-experience-recoverable.ps1`
- `test-msix-safe-install.ps1`
- `test-repair-deployment-state.ps1` in PowerShell 7 and Windows PowerShell 5.1, with spaces and Chinese characters in the temporary path
- `test-service-tier-access-patterns.ps1` (943 checks)
- `test-fast-mode-gate-patterns.ps1`
- `test-desktop-feature-slot-patterns.ps1`
- `test-computer-use-surface-patterns.ps1`
- `test-custom-model-visibility-patterns.ps1`
- `test-staged-package-selection.ps1`
- `test-asar-integrity.ps1 -CheckInstalledPackage`, including read-only verification of installed `26.1016.8120.0`
- Recursive PowerShell parse of `scripts/` and `automation/`, plus `git diff --check`

Deployment and cleanup fixtures use mock installation and disposable files. No real installation, native screenshot/input or Windows 10 validation was repeated for this merge.
