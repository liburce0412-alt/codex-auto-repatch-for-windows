# Upstream and installed-runtime review - 2026-10-29

## Reviewed sources

- Fork baseline: `52ae6d178614d2682e82eb7a40e193ce23286762`.
- Upstream main remains `14b418f71b3cd56b3c1cca41db5933dfbc30fbd1`; there are no new main commits.
- Integrated open [PR #112](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/112) at `33003143137b0218cd804f54a771c98959fa4334` (also includes `8a3f959c083ac01a00ef037c656af061a77edb99`). It preserves JavaScript model-probe bytes under Windows PowerShell 5.1, refreshes target runtime/native-host state before strict post-install acceptance, and accepts an enabled Edge extension through the official Edge-profile diagnostic.
- Preserved the fork README structure, C: build paths, PowerShell 7 default executable selection, model/launch overlays and explicit-only synchronization policy. Updated matching Chinese and English browser-verification guidance.
- Reviewed open [PR #113](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/113) at `c549dd2aba51236a850c01bb145aa846b087d2a4`; not integrated. Its strict path requires the newly managed proxy block whenever an explicit Windows proxy is enabled. A read-only run against this host's unmodified, package-matching CUA launcher returned `CUA runtime proxy patch missing or proxy URL drifted`, while the existing scoped verifier passed. This establishes a local verification-contract incompatibility, not a demonstrated live browser/proxy failure. The current request does not call for changing proxy routing or applying a runtime patch.
- Existing open issues #93, #94, #95, #100 and #104 have no new activity since the previous review that supplies an applicable fix.

## Verification

The following passed on both PowerShell 7 and Windows PowerShell 5.1:

- `test-model-list-probe-transport.ps1`: exact production model-probe functions, non-ASCII/space paths, advertised tiers, missing-priority rejection and temporary probe removal.
- `test-post-install-runtime-refresh.ps1`: refresh before strict acceptance, refresh failure short-circuit and strict failure rejection.
- `test-desktop-chrome-profile-visibility.ps1`: Chrome and Edge fixtures, disabled/missing extension rejection and caller-profile preservation.
- `test-repair-deployment-state.ps1`: 81 checks per shell.
- `test-model-experience-recoverable.ps1`: 92 checks per shell.

The initial 5.1 Edge fixture exceeded the legacy path-length limit under a deeply nested temp root. It passed from a short isolated fixture directory; no application or build path was relocated.

All 72 PowerShell scripts under `scripts/` parse, and `git diff --check` passes. No CommonJS, ASAR-integrity implementation/call site, or package-selection code changed, so their unrelated regressions were not repeated.

Both modified model-probe functions also passed against the current user-local CLI under PowerShell 5.1. This verifies model metadata and advertised `priority`, not request-wire Fast behavior. The merged scoped strict verifier passed against the current package, including real `list_windows` enumeration.

## Installed state and limits

Installed Desktop remains `26.1023.6123.0`, Developer/Ok, with a responsive target-package window and the matching managed CLI. The app updater reports `restart_required` without a target version; that is not compatibility or installation evidence. No reinstall or restart was performed.

The additional full-descriptor check still fails because the local stable marketplace contains legacy `sites` and `user-writing` descriptors absent from the package. Optional plugin state was preserved. Chrome-auth compatibility for the new header profile is not claimed.

The prior successful-update cleanup remains complete. Only this review's disposable fixtures are removed. Browser page interaction, native screenshot/input, a new package deployment and its post-install refresh were not exercised.

## Publication scope

Publish this tested integration to fork main and fast-forward the installed skill while retaining the nine existing local overlays. PR #112 and #113 remain upstream-owned open PRs; this review neither merges them upstream nor posts comments. No duplicate PR is needed because the applicable implementation is already in #112. Remote commit verification is recorded in the publishing session.
