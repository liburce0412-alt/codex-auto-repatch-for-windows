# Upstream merge: 2026-10-07

Merged upstream `2a4a19b5337bf2b2c7d1510b6f7542a0395e0661` into the fork
based on `f3df7eb89c61115c16e68d1320a577336561b10e`. Before merging, the fork
was 40 commits ahead and six commits behind upstream.

| Commit | Change |
| --- | --- |
| `4d5db47` | Exact Desktop 26.930 Chrome and Win10 helper profiles |
| `7775310` | Browser accessibility asset repair, Unicode transport, complete proxy diagnostics and targeted modes |
| `47506bc` | Desktop 26.930.7945 preparation and proxy-subset evidence |
| `a64d8b6` | Background verification, Chrome 26.930.61225 profile, proxy evidence and artifact retirement |
| `9ed6051` | Merge PR #90 with support and evidence boundaries |
| `2a4a19b` | Revert artifact retirement; its scripts and reference remain absent |

## Conflict resolution

- Retain the fork's README, explicit-only GitHub synchronization, automatic
  exact-version artifact handoff, optional CLI suppression and runtime recovery.
  Incorporate upstream's background verification guidance in both languages.
- Union the complete-hash Chrome and Win10 helper profiles without duplicates:
  15 Chrome profiles and 38 helper profiles. Preserve the fork-only `0D00DFDA`
  helper and `26.928.31416` Chrome entries. Upstream helper blocks are unchanged.
- Adopt upstream's null independent-validation fields for `25D792D0` and
  `6EEAF314`; contributor-reported capture results are not new local acceptance.
  The retained `0D00DFDA` metadata is inherited evidence, not a fresh live test.
- Run the new accessibility asset repair before the fork's existing scoped
  plugin-alignment check, and keep both read-only verification paths.
- Reject `OnlyBrowserComputerUse` with either new proxy-targeted mode. Extend
  the existing mode regression to cover these two integration conflicts.
- Keep machine-specific launcher/proxy overlays outside the merge. The six
  existing modified/untracked files were checked by SHA-256 before integration.

## Validation

All 19 regression groups below passed. Tests used isolated files on D:; installed
package inputs were read-only. The only Windows PowerShell 5.1 execution was the
accessibility suite's explicit cross-version wrapper compatibility check.

- PowerShell parsing: 72 files; changed CommonJS syntax: four files; Python
  syntax: two files; `git diff --check`.
- Accessibility assets: 52 checks, including Unicode paths and both PowerShell
  wrappers; process-environment probe: 12 tests, including owned native children.
- Proxy-targeted modes: 8 and 9 conflicting options rejected, 11 orchestration
  cases; existing Node proxy tests: 12 behavior and 5 guard cases.
- ASAR integrity synthetic tests and installed-package integrity; staged-package
  selection; browser feature hooks and sidebar gates; CUA surface; custom-model
  visibility; Desktop feature slots; Chrome browser-client trust contract.
- Exact external-artifact version: 16 checks; signing certificate reuse;
  packaged-runtime recovery; automatic update safety.
- Chrome `26.930.61225`: 52 policy/guard checks with output hash
  `6b8b0831ff70dce1c4a23eb0abc0ba01a1affcd253905edffa03c333e5c86614`;
  plugin/runtime cache scope: 44 checks.
- Retained `0.7.5-0D00DFDA` helper: isolated candidate hash, idempotent status,
  Windows 11 installation rejection and unknown-input rejection.
- Profile union checks confirmed every upstream helper block and every retained
  fork-only helper block is unchanged; Chrome profiles match the union exactly.

The first cache-scope test could not copy an EFS-protected WindowsApps source
with `Copy-Item`. Content-only D: fixtures were created from the same source
bytes, verified by SHA-256, and the regression then passed. No installed file
was changed to work around that test-input limitation.

The production `Invoke-PatchAppAsar` function also passed a Browser/Computer Use
and custom-model dry run against a hash-verified D: copy of the installed
`26.930.7945.0` ASAR and its 37 unpacked files. All selected targets matched and
patched asset syntax passed. Both the installed and copied ASAR retained SHA-256
`611D6DA979D8BBABFEC97DD90DCCE27A9522E7016E6CCF135D59CAB693AB08DA`.
An initial incomplete fixture omitted `app.asar.unpacked` and failed extraction;
the complete fixture above passed. This is source-target compatibility evidence,
not a newly signed/installed MSIX or future-build acceptance.

Boundary: the new `6EEAF314` original helper was unavailable locally, so its
binary candidate/unwind and Windows 10 capture/input checks were not run.
No Desktop repack, install, restart, live cache repair, model/config change or
automation deployment was performed for this source merge.

## Open PR review

Reviewed [upstream PR #91](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/91)
at head `30304a841d0f426d3a2fa037569c0377ff287716` against `2a4a19b`.
It contains two documentation commits and changes only
`references/restriction-debug-cases.md` (seven added lines, one removed line).
No executable patch, launcher, installer or profile is introduced. This review
does not merge the still-open PR or reproduce its contributor's live tests.

The record distinguishes Desktop 26.1002.6548 native transport and Chrome
success from unresolved in-app-browser `ERR_CONNECTION_CLOSED`. Its two browser
service hashes remain outside the exact header profiles; the optional
all-bundled assertion still cannot discover `deep-research`; native screenshots
and input were not exercised. These limitations are stated consistently and do
not establish a new blocking defect in this documentation change. Existing
combined proxy/surface repair matches the production paths retained here, but
26.1002 was not installed or independently accepted by this merge task.
