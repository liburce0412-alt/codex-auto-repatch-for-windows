# Upstream merge: 2026-09-30

Merged upstream 209d3b02156de590adaacab99c4a52b281f60110 into fork 7d4319731e633a4341b898895bfc0518217119ba.

Includes safe TOML string escaping and pre-write validation, Desktop 26.928 browser feature slots, and exact-hash Chrome/browser-desktop runtime profiles.

Conflict resolutions retain boolean TOML key values, bounded patched receiver matching, and scoped plugin verification tests. The fork's separate browser-only target finder also receives the 26.928 optional mcpAppsBrowserUse slot; the first regression run exposed this additional integration requirement. The MCP Apps slot value remains unchanged by the patch.

Verification passed (11 suite runs):
- test-toml-config-writing.ps1: 108 round trips / 347 assertions
- test-desktop-feature-slot-patterns.ps1
- test-computer-use-surface-patterns.ps1
- test-custom-model-visibility-patterns.ps1
- test-staged-package-selection.ps1
- test-asar-integrity.ps1 -CheckInstalledPackage
- test-browser-sidebar-gate-patterns.ps1
- test-repatch-dry-run-cleanup-arguments.ps1
- test-chrome-header-cache-scope.ps1 with a supported runtime: 44 checks
- test-chrome-custom-provider-headers.cjs on Chrome 26.924.20706: 51 checks
- test-chrome-custom-provider-headers.cjs on browser-desktop fc0660ba: 53 checks

All 51 PowerShell scripts parsed; both changed CommonJS files passed node --check; git diff --check passed. The TOML test used the existing Python 3.13 directory on the child process PATH. Chrome fixtures used byte-identical data copies of installed source files to avoid inherited WindowsApps EFS attributes.

The newer 26.928.20755, 26.924.51851 and 64b3e675 source binaries were unavailable locally; no claim of their live acceptance is made. No Desktop installation, restart, configuration write, or live service patch was performed. The automation tree and automatic GitHub-update opt-out remain unchanged.
