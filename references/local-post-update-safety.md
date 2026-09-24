# Local post-update safety overlay

This machine's external executor lives under `%USERPROFILE%\.codex\automation`.
The standing task invokes the exact-version watcher; the application being
repaired must not host its own installer.

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
mandatory. Never fall back from
`Remove-AppxPackage -PreserveApplicationData` to ordinary removal.

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

## Cleanup

The prepare process uses only
`install-handoffs\<authorization-id>\build` for the new build. Before installation,
record the exact files, lengths and SHA-256 hashes in `cleanup-manifest.json`.
Cleanup runs after the exact Developer package, finalization and stable window
checks have passed. It revalidates the run ID, state, path boundaries, absence
of reparse points and every file's content. Changed or extra files defer cleanup.

Remove only the recorded build files and empty build directories. Keep the
official recovery MSIX, signed patched MSIX, handoff records, compact logs and
cleanup report. Keep configuration, credentials, conversation data, runtime and
all unrelated paths. Failed runs retain build/evidence for diagnosis; deletion
of old failed runs is a separate manifest-based cleanup after recovery is proven.
A cleanup error must not turn a successfully repaired Desktop into a failed
repair or trigger rollback; report cleanup as deferred.

## Validation boundary

Source tests cover legacy/modern CUA behavior and PR #62 migration. Automation
tests exercise deployment decisions with mocked Windows deployment commands and
cleanup on disposable fixtures. A read-only installed ASAR copy validates CUA
migration. These do not prove a new Store update, UAC installation, restoration
or real post-update restart. Record those only after an actual authorized cycle.
