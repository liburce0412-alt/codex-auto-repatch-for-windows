# Upstream review and integration — 2026-10-18

## Sources and scope

- Upstream main: `ae0c9fcc8338947c358b62fc326033dac867f0e1`, four commits beyond the previous upstream baseline `43ac02c`. PRs [#97](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/97) and [#98](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/98) were merged on 2026-10-16. The fork already contained #97's original cache/SDK behavior; the merge preserves one implementation and adds upstream's npm-config error handling and PowerShell 5.1-compatible fixtures.
- Open PR [#99](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/99): reviewed and integrated through `0653fe9a3cd6507d192517794d08236159f47b31`. Its two commits add a missing optional Node lookup to the acquisition-fallback mock and document separate custom stdio MCP proxy diagnosis. It remains open upstream.
- Open issues [#93](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/93), [#94](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/94) and [#95](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/95): no activity since the previous check. The first two concern Windows 10 capture; #94 has a contributor's experimental profile report, not an upstream-validated new profile. #95 reports a missing Windows 10 tray icon. No new issue or applicable production fix was found. The fork has no open issues or PRs.

## Merge decisions

- Retain the fork's README structure and existing cache/SDK description once; update both language variants and clarify that all ordinary/history cleanup is separate.
- Use upstream's guarded npm-cache discovery and eight-case regression suite. Keep the fork's source-version, payload-validation and independent-executor contracts.
- Incorporate public-page browser guidance without treating third-party page layout or connection failure as evidence that repatching is needed.
- Preserve local uncommitted storage/launcher overlays and `.skill-auto-update-disabled`. Do not change credentials, model routing, proxy configuration or scheduled-task authorization.

## Verification

- PowerShell parser: all 58 files under `scripts`, including nested libraries, passed.
- PowerShell 7.6.5 and Windows PowerShell 5.1: eight offline ASAR cache cases and the complete Computer Use surface suite passed, including acquisition fallback, readiness migration and behavior matrices.
- PowerShell 7: ASAR integrity fixtures, browser feature-hook fixtures, custom-model visibility fixtures, staged-package selection and all 16 external-artifact producer/version checks passed.
- Syntax and fixture checks use disposable task-owned data. ASAR integrity hashing is part of the required fixture contract; no installed-package or unrelated-file hash inventory was run.
- No Desktop installation, restart, native input/capture or proxy repair was performed. Fixture success does not establish live UI or network-routing acceptance for a new package.
