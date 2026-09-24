# Codex Auto Repatch for Windows

[简体中文](README.md)

Reapply compatible local Codex Desktop patches after Microsoft Store updates, show live terminal progress, and open an independent Codex CLI if repair fails. Maintained by [liburce0412-alt](https://github.com/liburce0412-alt).

## Workflow

1. A Windows scheduled task observes Store registration events, with a delayed logon check. No persistent polling process is required.
2. An external executor verifies the exact package and prepares a signed patch. A separate terminal streams real stages and child-process logs; closing the viewer does not stop the worker.
3. Before replacing the Store package, verify the independent CLI, patch identity, version, signature and hashes, then create a verified application-data backup.
4. Install the exact artifact, restore user application data, finalize the repair and verify a stable Desktop window.
5. Only after success, remove unchanged build files covered by this run's cleanup manifest. Keep data backups, signed artifacts and diagnostic records.

Failures open one interactive CLI terminal with the existing configuration and no automatic prompt. A failed Store version is not retried repeatedly. Original signed Store recovery media is optional; application-data backup is mandatory. If installation fails after removal, Desktop may be unavailable until reinstalled through Microsoft Store; the workflow does not automatically redeploy Store as its fallback.

The automatic scope is Chrome/Browser, Windows Computer Use and custom-model visibility. Other manual tools remain available in [SKILL.md](SKILL.md). Unknown bundle layouts stop preparation instead of being treated as compatible.

## Install

Requirements: Windows x64, Codex Desktop installed for the current user, Git, and an independently installed PowerShell 7.5 or later. The patch tools check build prerequisites; the first build may download Windows SDK tools. Allow disk space for extracted packages and application-data backups.

Run from an external PowerShell window. For an existing installation, preserve and inspect local changes instead of overwriting or resetting them.

```powershell
git clone https://github.com/liburce0412-alt/codex-auto-repatch-for-windows.git "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"
Set-Location "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"
pwsh.exe -NoProfile -File .\scripts\install-update-automation.ps1 -EnableAutomation
```

The existing directory name is required for skill/path compatibility. `-EnableAutomation` grants continuing, current-user authorization and registers `Codex Desktop Post-Update Repair`. Future Store updates may close and repair Desktop automatically. Setup backs up old scripts and verifies the independent CLI; it does not immediately repatch Desktop.

After explicitly updating the repository and reviewing changes, redeploy scripts while preserving current authorization:

```powershell
pwsh.exe -NoProfile -File .\scripts\install-update-automation.ps1
```

This fork does not automatically synchronize upstream code on skill invocation or patch failure.

## Status and deliberate retry

```powershell
Get-ScheduledTask -TaskName 'Codex Desktop Post-Update Repair'
Get-Content "$env:USERPROFILE\.codex\automation\update-cycle-active.json" -Raw
```

After fixing the failure, retry the same Store version from an external PowerShell window; this closes Desktop:

```powershell
$root = Join-Path $env:USERPROFILE '.codex\automation'
$authorization = Get-Content (Join-Path $root 'standing-update-authorization.json') -Raw | ConvertFrom-Json
& (Join-Path $root 'invoke-codex-standing-update.ps1') -StandingAuthorizationId $authorization.authorization_id -RetryFailedVersion
```

Do not add `-RetryFailedVersion` to the recurring task. To disable future runs:

```powershell
Disable-ScheduledTask -TaskName 'Codex Desktop Post-Update Repair'
```

Disabling the task does not cancel an active deployment. Do not terminate a package installation in progress. UAC, if required, applies only to installation of the exact verified MSIX.

## Local records and recovery

Runtime records live under `%USERPROFILE%\.codex\automation`. Logs are in `logs`; each `install-handoffs\<run-id>` contains the artifact and installation records. Its `appdata-backup` is retained, while `build` is eligible for manifest-verified cleanup after stable success. Optional original media belongs at `store-recovery\<version>\original.msix`.

The independent CLI and companion executables live under `%LOCALAPPDATA%\OpenAI\Codex\bin\post-update-<version>`, outside WindowsApps. Opening a terminal does not prove API/network access. Never publish authorization records, credentials, logs, application data, generated packages or signing keys. See [update safety and cleanup](references/local-post-update-safety.md).

When application data on another AppX volume carries EFS encryption, ordinary file copying can fail with an encryption error. Backup and restore now copy file content through streams while retaining hash and path-boundary checks; a failed backup still blocks removal. Update and redeploy the automation scripts before deliberately retrying this failure. See the [encrypted-file backup case](references/local-post-update-safety.md#encrypted-application-data-2026-09-24).

## Validation

The 26.917 overlay integrates CUA readiness recognition, older patch migration and proxy environment propagation. A real local installation of 26.917.8451.0 completed on 2026-09-24 after the encrypted-file backup fix: application-data backup and restore hashes, Developer package installation, stable restart and build cleanup passed. The installed ASAR matched the validated patched artifact; plugin/runtime checks and window enumeration passed. Actual Chrome page interaction remains unverified, and this result does not establish compatibility on every machine or future version. Automation fixtures still use disposable files and mocked deployment commands; they do not uninstall the current app.

```powershell
pwsh.exe -NoProfile -File .\automation\tests\test-update-safety.ps1
pwsh.exe -NoProfile -File .\automation\tests\test-appdata-backup.ps1
pwsh.exe -NoProfile -File .\automation\tests\test-update-progress.ps1
pwsh.exe -NoProfile -File .\automation\tests\test-superseded-watcher.ps1
pwsh.exe -NoProfile -File .\scripts\test-computer-use-surface-patterns.ps1 -TemporaryRoot "$env:TEMP\codex-auto-repatch-tests"
```

## Origin

Derived from [chen0416ccc-cpu/codex-windows-fast-patch-skill](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill), retaining its patch tools and Git history, with selected community fixes. This README was rewritten for this fork; its automation, CLI fallback and cleanup behavior are defined by this repository. This is not an official OpenAI project.
