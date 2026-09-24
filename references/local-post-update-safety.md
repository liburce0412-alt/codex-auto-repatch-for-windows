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

## Store fallback

Before any Store removal, the watcher requires
`store-recovery\<exact-version>\original.msix` under the automation directory.
This must be the original signed x64 Store MSIX, not an extracted folder or a
locally re-signed build. It verifies Authenticode, manifest identity, version,
architecture and the embedded signature against `AppxSignature.p7x` of the
registered Store package. It copies and hashes the verified original into this
authorization's install handoff directory and rechecks it before deployment.

The watcher does not download or fabricate official recovery media. Missing or
invalid media blocks replacement and keeps Store installed; a successful local
patch build in that case is **not** an installed patch. Never fall back from
`Remove-AppxPackage -PreserveApplicationData` to ordinary removal.

If patch installation, finalization or stable-start verification fails, keep an
intact Store package, or attempt restoration from the verified original, then
check the exact package and window responsiveness. A rollback deployment can
itself fail; report that result and retain the recovery files. Never claim Store
was restored based only on an installation command's exit code.

After a failed attempt, the standing task does not keep restarting the same
Store version. A newer Store version is eligible; a deliberate exact-version
retry uses the existing armer after the failure is fixed.

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
