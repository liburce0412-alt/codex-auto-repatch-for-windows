# Upstream merge: 2026-10-01

Merged upstream `459ed73` into the fork based on `f58c3ba`. The eight upstream
commits are `fd6d38e`, `b787824`, `7592157`, `5e363a2`, `fe712c8`, `8263c7c`,
`2a7d2ce`, and `459ed73` (PRs #80–#82).

Changes include optional official MSIX download fallback for Store NoUpdates,
hash-pinned Windows 10 sky 0.7.4/0.7.5 capture and x64 unwind support, the
Desktop 26.928.2636 Chrome service profile, and BOM-tolerant TOML stdin validation.

Integration preserves the fork's automatic exact-version handoff and scope.
The new updater option is rejected in the fork's Browser/Computer Use-only mode
before output paths are created, because its implementation belongs to full mode.
The local TOML interpreter discovery fix is included: prefer the Python launcher
over Store aliases and use a probe whose native quoting works in PowerShell 5.1.
Existing machine-specific package-path/launch changes remain local and were
backed up before merging. The automatic GitHub-update opt-out remains present.

Validation passed:
- 70 PowerShell files parsed; four changed CommonJS files passed `node --check`;
  the new Python unwind verifier parsed; `git diff --check` passed.
- TOML writing: 108 round trips / 349 assertions under PowerShell 7 and Windows
  PowerShell 5.1; interpreter discovery: 10 assertions.
- Package selection, Windows CUA surface, custom-model visibility, browser hook
  and sidebar, Desktop feature slots, and external artifact version suites.
- ASAR integrity synthetic regression and read-only installed-package check.
- Automatic update safety regression with isolated deployment mocks.
- Current Chrome 26.928.21956 service: 53 header-policy assertions; independent
  browser-desktop 64b3e675 service: 54 assertions; cache/runtime scope: 44 checks.
- Store fallback: eight behavior cases plus idempotence, partial and duplicate
  branch guards on a patched copy of the installed updater asset.
- Full-mode updater scope rejection including Browser/Computer Use-only mode.

Boundary: tests modify isolated fixtures only. The currently shipped sky 0.7.5
helper hash `25D792D0...7AD82910` is outside the new profiles and was correctly
reported unsupported, without modification. The newly supported Win10 binaries
were unavailable locally, so their candidate/unwind and real capture acceptance
were not run here. No Desktop installation, restart, live service patch, or
configuration write was performed as part of this source merge.
