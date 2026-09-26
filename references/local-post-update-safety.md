# Local post-update safety overlay

This machine's external executor lives under `%USERPROFILE%\.codex\automation`.
The standing task invokes the exact-version watcher; the application being
repaired must not host its own installer.

## Source-version handoff and upstream direct installers

The automatic watcher requires the authorized source version and package identity.
Its producer passes `-PreserveSourceVersion -OnlyBrowserComputerUse -ForceRebuild`
for preparation only; `-PreserveSourceVersion -Install` is rejected before work.
The post-update repair entrypoint requires `-PrepareExternalInstall` for a full
repatch. It cannot silently enter the generic revision-incrementing installer.
Every newly signed artifact passes MSIX block-map payload verification before
publication, followed by the watcher's existing identity/signature/hash checks.

The generic manual patcher uses upstream's guarded revision-incrementing in-place
update instead. Neither path is a fallback for the other's failed validation.
This distinction preserves the existing authorized exact-version replacement,
optional original Store media, mandatory data snapshot and CLI fallback below.

## Progress

`show-codex-update-progress.ps1` opens a separate PowerShell terminal after the
watcher's authorization checks. It follows current-run stage events, child
stdout/stderr and nested patch/build logs while the processes run. It shows a
heartbeat during silent work, not an invented percentage. Closing the viewer
does not cancel the worker. Results remain visible until Enter is pressed.

## CLI fallback (user choice, 2026-09-24)

The user cancelled mandatory recovery media and explicitly chose CLI fallback.
The watcher may optionally retain
`store-recovery\<exact-version>\original.msix` under the automation directory.
This must be the original signed x64 Store MSIX, not an extracted folder or a
locally re-signed build. It verifies Authenticode, manifest identity, version,
architecture and the embedded signature against `AppxSignature.p7x` of the
registered Store package. If available and valid, the original is copied into
this authorization's install handoff directory for later manual recovery.

The watcher does not download or fabricate official recovery media. Missing or
invalid recovery media does not block installation of a validated patch. Patch
identity, exact version, hash, signature, producer and runtime contract remain
mandatory. The Store package is not a loose-file development registration, so
`Remove-AppxPackage -PreserveApplicationData` is not applicable. Before normal
exact-current-user removal, stop the app and create a mandatory, hash-verified
application-data snapshot. A backup failure stops removal. Restore user data
before restarting the patched app; retain Windows-owned SystemAppData, AC and
TempState only in the snapshot, without overwriting new deployment metadata.
The snapshot is separate from optional original installation media and is not
part of build cleanup. Known Windows AppX-volume junctions must match the
current SID and exact package family; unknown or nested links fail closed.

Before replacement, verify the independent CLI under
`%LOCALAPPDATA%\OpenAI\Codex\bin\post-update-<version>` and its companion files.
The main CLI hash must match the state recorded when copied from the package.
If preparation, installation, finalization or stable-start verification fails,
open an interactive CLI terminal once, with the failure reason and log location.
Use existing model routing and configuration; send no automatic task prompt.
Do not uninstall or redeploy a package as part of this failure fallback. Retain
diagnostic files. A terminal launch is not proof of successful CLI API access.

After a failed attempt, the standing task does not keep restarting the same
Store version. A newer Store version is eligible; a deliberate exact-version
retry uses `invoke-codex-standing-update.ps1 -RetryFailedVersion` with the existing
standing authorization after the failure is fixed. Do not add that flag to the
recurring standing task.

## Encrypted application data (2026-09-24)

On Store version `26.917.8451.0`, the mandatory snapshot failed while copying a
log from an AppX volume's `WpSystem` package-data directory. The source carried
the `Encrypted` attribute. `File.Copy` attempted to propagate encryption to the
backup destination and raised an encryption error. The installer stopped before
`Remove-AppxPackage`; the current-user package remained `Store / Ok`, and the
independent CLI fallback opened.

`Copy-CodexDataContent` now streams readable file content into a destination
created under its own filesystem policy, without copying source EFS attributes.
It does not decrypt or change the source. Backup uses `CreateNew` to prevent
overwriting recovery evidence; restore uses `Create` to truncate stale content.
Streams are disposed on failure. Existing source/destination SHA-256 checks,
snapshot inventory verification and junction/path checks remain in force.

Regression coverage includes an optional existing encrypted source, content
round-trip, empty files, truncation of longer restore targets, rejection of an
existing backup, path traversal, nested junctions and corruption before restore.
To exercise the EFS path, supply a readable encrypted fixture (its content is
copied into the local ignored test directory; do not publish that directory):

```powershell
pwsh.exe -NoProfile -File .\automation\tests\test-appdata-backup.ps1 -EncryptedSourcePath '<path-to-encrypted-fixture>'
```

After deployment and a deliberate retry under the existing authorization, the
real cycle backed up and restored 871 files with hash verification, installed
the exact `Developer / Ok` package, passed stable restart and removed the
manifest-recorded build cache. A subsequent read-only check confirmed that the
installed ASAR matched the validated patched artifact, plugin/runtime checks
passed and window enumeration succeeded. Chrome page interaction was not tested.
These results describe this local cycle, not blanket compatibility for future
Store releases. Failed-run evidence remains separate from the successful run.

## Cleanup

The prepare process uses only
`install-handoffs\<authorization-id>\build` for the new build. Before installation,
record the exact files, lengths and SHA-256 hashes in `cleanup-manifest.json`.
Cleanup runs after the exact Developer package, finalization and stable window
checks have passed. It revalidates the run ID, state, path boundaries, absence
of reparse points and every file's content. Changed or extra files defer cleanup.

Remove only recorded files and empty directories. Keep the latest successful
run's application-data backup and signed patched MSIX, optional official media,
compact logs and cleanup reports. A second manifest-based pass automatically
removes superseded handoff directories (including historical failures) and older
`post-update-<version>` CLI copies after recovery is proven. It first verifies
the latest completed handoff, recovery artifact hash, backup manifest and running
Desktop path. Preserve the current run/version, newer or unrecognized versions,
and executable paths referenced by running processes or active configuration.
Historical native-host registration entries alone do not establish active use.
Never follow junctions; persist the inventory outside deletion targets and
recheck hashes before removing files. Preserve configuration, credentials,
conversation data, shared runtimes, source and all unrelated paths. Failed runs
remain available until a later stable successful repair allows this cleanup.
A cleanup error must not turn a successfully repaired Desktop into a failed
repair or trigger rollback; report cleanup as deferred.

## Validation boundary

Source tests cover legacy/modern CUA behavior and PR #62 migration. Automation
tests exercise deployment decisions with mocked Windows deployment commands and
cleanup on disposable fixtures. A read-only installed ASAR copy validates CUA
migration. These do not prove a new Store update, UAC installation, restoration
or real post-update restart. Record those only after an actual authorized cycle.
