# Open PR integration and local repair: 2026-10-01

Base: fork `edab99d`, containing upstream main `459ed73`. The following open PR
heads are integrated into the fork; this does not merge them into the original
repository or imply that later revisions of those PRs are included.

| PR | Pinned head | Scope |
| --- | --- | --- |
| [#83](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/83) | `faddd02` | Win10 sky 0.7.5 helper `25D792D0`, shipped in 26.928.2636 |
| [#84](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/84) | `ad645cc` | Chrome service 26.928.31416, shipped in 26.928.3736 |
| [#85](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/85) | `8332304` | Win10 helper `0D00DFDA` for 3736 and the same Chrome service profile |

## Conflict resolution

Both new helper profiles retain their exact upstream fields and thirteen guarded
regions. They are separate binaries and must not replace one another just because
both report sky 0.7.5. The test selector and reference table contain both labels.
All 35 preceding profiles remain identical to upstream main. Both PR helper
inventories were compared field by field with the merged inventory.

The Chrome profile and output-hash assertion shared by #84 and #85 appear once.
The source hash, policy anchor, missing-token-only fallback, output hash and
other guards remain unchanged. Author-reported acceptance records for each
Desktop build are retained; they are not acceptance results from this machine.

## Current-machine repair

Installed package: `26.928.2636.0`, Developer signature, status Ok. System:
Windows 11 build 26200. Initial live Chrome navigation and accessibility reads
worked, but strict local verification found the supported header overlay missing
from the mutable browser marketplace copy.

The normal scoped `install-computer-use-local.ps1 -VerifyOnly
-BrowserComputerUseOnly -SkipUserEnvironment` repair refreshed the browser,
Chrome and Computer Use caches and applied the exact 26.928.21956 overlay to
six mutable plugin-service copies. The independent browser-desktop runtime
already contained its correct 64b3e675 overlay and was left at that exact hash.
The subsequent `-StrictVerifyOnly -BrowserComputerUseOnly` check passed without
skipping user-environment verification. Trusted browser-client bytes remain
identical to the installed package.

Configuration comparison found only the marketplace timestamp and the notify
helper path changed. Notify now points to the current user-runtime helper rather
than the packaged copy; both executable hashes and all notify arguments match.
Provider selection, model routing, permission settings and unrelated configuration
remain unchanged. Existing local automation edits and the GitHub-update opt-out
are preserved. Backups and test artifacts remain outside the repository.

## Local validation

- All 70 PowerShell files parse; both changed CommonJS files pass `node --check`.
- Current 21956 plugin header regression: 53 checks; independent 64b3e675 runtime:
  55 checks; cache/runtime scope regression: 44 checks.
- The real original `25D792D0` helper passes the existing isolated harness:
  candidate output hash, Windows 11 install rejection without file mutation,
  and unknown-input rejection.
- A candidate file generated only in the test directory passes native unwind
  validation at 47 instruction boundaries and ten live caller frames (3 callback
  success, 3 CreateThread failure, 4 worker). No live helper is patched or run by
  this fixture test; the verifier uses a private mapping and API/COM stubs.
- After reconnecting to the repaired Chrome service, a loopback-only fixture
  passes tab creation, navigation, accessibility and DOM reads, Chinese input,
  button activation and a visually inspected screenshot showing the result.
- Full local strict verification also passes runtime import and native window
  enumeration. `git diff --check` passes.

## Remaining boundaries

No Desktop update, reinstallation or restart was performed. The live Windows 11
helper remains unmodified. Candidate testing does not establish actual Win10
capture, installation/rollback, language-level exception dispatch or resource
soak on this machine.

Original 3736 service/helper fixtures are unavailable locally. Their profiles are
integrated with exact source preservation, syntax and guard inspection, but their
positive candidate/cache/native tests and real 3736 deployment were not run here.
The upstream PR authors' tests are recorded separately in the existing references.

Neither `nodeRepl.fetch request failed` nor AX `Decompression failed` reproduced
in this local acceptance. This repair does not broaden the fallback to those
errors and does not establish their root cause on other machines. Issue #78's
independent runtime coverage and Issue #79's TOML apostrophe handling remain
present without further changes.
