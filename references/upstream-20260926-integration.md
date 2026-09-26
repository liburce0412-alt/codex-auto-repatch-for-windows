# Desktop 26.924 update integration

Reviewed on 2026-09-26 against the original author's repository,
`chen0416ccc-cpu/codex-windows-fast-patch-skill`.
The installed Desktop remains `26.917.9434.0 / Developer / Ok` during this work.
The updater reports a downloaded update, and the actual staged package inspected
is `26.924.1866.0`, with Chrome plugin `26.924.20706`.

## Reviewed sources

| Source | Reviewed revision | Decision |
| --- | --- | --- |
| [Main](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/commit/cc845d7e3c40bf3027dc30c0bae50c9fac94b697) | `cc845d7e3c40bf3027dc30c0bae50c9fac94b697` | Merge guarded manual MSIX installation, runtime/instructions repair, GPT-6 Sol handling and Chrome header compatibility. |
| [Patched receiver recognition](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/68) | `420dffcefc4580ed76ef8606f5994fe483ce64e0` | Retain the fork's equivalent bounded receiver matcher and add the upstream regression coverage. |
| [MSIX payload verification](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/69) | `a8dd176751d582dc24f44406f760f7a0761e256b` | Integrate block-map payload validation; also validate signed prepared artifacts before publishing their path to the watcher. |
| [Chrome cache verification](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/70) | `6a226db2ee6f761df584abc7da3777887394f0c5` | Accept the exact source-derived header overlay in the browser-client check. Adapt the fork's scoped alignment check to the same exact exception. |
| [Renamed CUA surface locals](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/71) | `377cb53490cc97a7c1bfe7965f46f730c2a260d2` | Integrate structural matching and negative lookalike coverage for Desktop 26.924. |
| [Shared sidebar discovery](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/72) | `fc068b941cfbc3fdeb8ed2eb22f5c238950f59b3` | Submitted from this investigation. Apply the same discovery fix to both local patch scopes. |
| [New Chrome header profile](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/73) | `d6d5db3` | Submitted from this investigation. Add the exact 26.924.20706 source profile while keeping existing policy/error/provider guards. |
| [Additional Win10 helper profiles](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/67) | `5a6d0e62f117c66a41789c4bae011c8f53ff0812` | Reviewed but not applied: this machine runs Windows 11, and helper patching remains explicit opt-in. |

The upstream open-issues query returned no non-PR issues at review time. The
reviewed PRs were still open; their changes are locally integrated, not claimed
to have been merged by the original author. Automatic upstream fetching remains
disabled; this comparison was explicitly requested.

## Compatibility findings and preserved behavior

- The real staged package initially failed sidebar discovery: its unchanged
  capability shape moved from `app-initial-*` into `app-shared-*`. Both scoped
  and full discovery now search those names with the original content guards.
- Upstream revision-incrementing direct installers cannot feed the automatic
  watcher's exact-source-version handoff. Only external artifact preparation
  uses `-PreserveSourceVersion`; direct installation with it is rejected. Full
  automatic repatch requires the external watcher. Manual direct installation
  retains upstream's in-place update guard.
- Scoped cache verification accepts original browser service bytes or the exact
  overlay derived from that installed source. Other drift and mixed versions
  still fail. CLI registration completes before the final package cache sync;
  final alignment verification runs after the overlay.
- The new Chrome service initially reported an unsupported hash. Its reviewed
  profile now produces the exact expected header overlay. Actual request-method
  fixtures test both the missing-auth failure and header-enabled fallback;
  other policy errors remain failures.
- A profile-visibility test reproduced WindowsApps EFS copy failure. Its fixture
  setup now streams bytes and compares hashes, leaving the source untouched.
- Existing application-data backup, optional original Store media, CLI fallback,
  exact hash/identity validation and stable-start historical cleanup are kept.
  Global proxy variables are not introduced. Browser import diagnostics remain
  deferred until the next real repack and do not claim a Cookie import fix.

## Validation and limits

The actual staged `26.924.1866.0` package passed a complete dry run with
`-OnlyBrowserComputerUse -IncludeCustomModelVisibility -PreserveSourceVersion
-ForceRebuild -DryRun`. Browser/Chrome, Computer Use surface/readiness, import
diagnostics, trusted paths, proxy forwarding and custom-model targets patched
successfully in disposable copies. All modified assets passed Node syntax checks.
The new executable's ASAR integrity entry was located. No MSIX was installed.

Passed regressions:

- Sidebar discovery: 18 checks in the fork, 12 on the upstream PR branch;
  the latter fails on unmodified upstream main and passes with the fix.
- Exact-version preparation and producer publication: 16 checks.
- Chrome header behavior: 48 checks each against the new and previous services;
  cache scope/alignment: 26 checks against the previous service, 29 with new
  service and cross-profile negative cases.
- MSIX payload: 8 cases; guarded manual installer: 51 checks.
- CUA surface/readiness, desktop feature slots, custom models, staged package
  selection, runtime repair, ASAR integrity fixtures, repatch result handling,
  dry-run argument forwarding, browser import diagnostics, Chrome profile
  visibility, update safety and history cleanup suites.
- Recursive PowerShell parsing, changed CommonJS syntax and `git diff --check`.

The ASAR fixture test's optional installed-package check reported no embedded
table in the old current package and skipped that live check; it is not evidence
of a successful new-version launch. Dry-run, fixture and static results do not
establish packaging, deployment, live Chrome control or Cookie import acceptance.
The user owns the update-button click; this session does not restart or install
Desktop. After that update, the existing authorized external repair workflow
must independently finish packaging, installation and stable-start verification.
