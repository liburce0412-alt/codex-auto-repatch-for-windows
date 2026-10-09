# Upstream integration: 2026-10-09

Merged upstream main through `a524256`. Seven previously unmerged commits include
the upstream merges of PRs #91 and #92, whose changes were already present in this
fork. No open upstream pull requests remained at review time.

New changes add two Desktop 26.1002 browser service profiles, two Sky 0.7.6 Win10
helper profiles, isolated Win10 capture diagnostics, and missing-TEMP installation
troubleshooting. Existing fork automation, older helper profiles, and the 26.825
custom-model regression fixture remain. README conflicts retain the fork guide
and link the new guest diagnostic. Personal storage preferences remain local.

Validation passed:

- PowerShell parsing: all 56 scripts under `scripts`; syntax checks on four changed CommonJS files; `git diff --check`.
- Custom-model visibility, including 5,760 access-program combinations; Computer Use surface and migration; browser feature hooks; staged-package selection; ASAR integrity fixtures.
- New capture-driver guard suite: 11 tests.
- Browser header suites against both original service files in installed Desktop 26.1002.7124.0: 63 assertions each.
- Sky 0.7.6-F78948E6 isolated candidate/hash, unsupported-file and Windows 11 installation-guard regression.
- Dedicated C# diagnostic target compiled without launching.

The second new helper profile (63C98C4D) was reviewed but its binary was not
available for local candidate testing. No Windows 10 capture/input acceptance,
Desktop repack, installation, restart, or active helper modification occurred.
Disposable fixtures and the compiled diagnostic target were removed after checks.
