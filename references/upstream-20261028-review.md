# Upstream review - 2026-10-28

- Fork baseline: `b4bfba91ffd75abd26f880b9135a1a76959fddd2`.
- Reviewed upstream main: `14b418f71b3cd56b3c1cca41db5933dfbc30fbd1`.
- The only new upstream commit merges [PR #111](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/pull/111), the physical WindowsApps path fix already integrated in this fork. Upstream merged it on 2026-10-26. There were no open upstream PRs at review time.
- Integrating that history leaves the runtime implementation unchanged. The sole existing-file change is a trailing newline in `scripts/test-repair-desktop-path.ps1`; the add/add conflict was checked for identical line content before resolution.
- Open issues #93, #94, #100 and #104 concern Windows 10 helper profiles. Issue #95 has an updated timestamp but no body or comments providing a fix. No additional applicable implementation was available.

## Validation and local scope

- Parsed all 70 PowerShell scripts under `scripts/`; passed. `git diff --check` passed. No CommonJS implementation changed.
- The physical-path regression logic is identical to the previously tested local version, so its runtime tests were not repeated for the newline-only merge.
- Reviewed both maintained READMEs; the merge changes no documented behavior, setup or usage.
- Preserved the local C: repatch paths, launcher/proxy overlays and disabled automatic-sync preference. No package installation or Desktop restart was performed by this review.
- Installed Desktop `26.1023.6123.0` was Developer/Ok with a responsive window. Its `ChatGPT.exe` ASAR integrity and `-StrictVerifyOnly -BrowserComputerUseOnly` checks passed, including real `list_windows` enumeration.
- The additional `-VerifyAllBundledPluginsAvailable` check failed because the stable local marketplace still contains legacy `sites` and `user-writing` descriptors absent from the new package. This remains a separate optional-marketplace discrepancy; no optional plugin was installed, removed or enabled.
- The separately requested cleanup removed only this successful update's build, used MSIX and ASAR workspace: 26,004 files, 5,768,703,941 logical bytes. Retained the current application, runtime, data snapshot, logs and useful shared caches. Detailed local evidence is retained with the update handoff, outside Git.

## Publication

The existing upstream PR is merged; no duplicate PR is needed. This integration belongs on [the fork main branch](https://github.com/liburce0412-alt/codex-auto-repatch-for-windows/tree/main). The publishing session verifies the remote commit after pushing and fast-forwards the installed skill without overwriting local overlays.

Native screenshot/input, browser page interaction and optional-plugin functionality were not exercised.
