# Investigating Windows 10 capture from a Windows 11 host

A Windows 11 development host can acquire authentic helper samples, compare all PE sections, reconstruct exact-hash candidates and verify native unwind. The missing evidence is execution against the Windows 10 graphics stack. Do not install the Windows 10 patch on the host or set a validation version based on offline checks.

## Choosing an execution environment

| Environment | What it establishes |
| --- | --- |
| Windows 11 host with exact official samples | Binary compatibility, candidate hashes, platform guards and native stack walking. |
| Windows 10 22H2/build 19045 guest with a visible local console | Real Windows 10 helper capture/input, using the guest's virtual GPU. |
| Reporter's Windows 10 machine | The reported physical GPU/driver path and original symptom. |
| Compatibility mode, Wine, Windows Sandbox on Windows 11, or a Windows Server CI runner | Does not reproduce the Windows 10 client graphics stack and cannot promote its capture validation. |

For a Windows 11 Home host without Hyper-V management tools, VMware Workstation is a practical guest option. A virtual GPU supporting Direct3D 11 and current guest tools avoids treating an unconfigured display adapter as a helper defect. VirtualBox is an alternative when its guest display path supports the required capture operations. Use a Windows 10 22H2/build 19045 image, around 4 GiB guest RAM on a 16 GiB host, and a dynamically allocated disk on a large local drive. A 40 GiB virtual disk has a growing physical footprint; allow space for installation, updates and runtime files. Host hypervisor detection can hide CPU virtualization flags, so those flags alone do not prove virtualization is disabled.

Run in the guest console with the desktop unlocked, a single display and 100% scaling for the optional coordinate test. Keep the guest console visible while testing. Headless execution, a minimized/disconnected remote session and another overlapping window can alter capture independently of the patch. A VM result does not cover every physical GPU/driver combination, so a reporter run remains useful even after guest success.

## Prepared diagnostic

`scripts/diagnose-win10-helper-capture.ps1` supports the exact original `@oai/sky 0.7.6` profiles. It does not update Desktop, its active helper, auth or the user's config. It compiles its own executable target, copies the helper into the evidence directory and runs the official runtime's Windows transport/client against that copy. Each helper process gets a disposable `CODEX_HOME`; this prevents the helper's notify-hook initialization from reserializing the real config.

The default command only reports helper/profile status and creates no test window or output directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\diagnose-win10-helper-capture.ps1"
```

On the development host, compile the target without launching it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\diagnose-win10-helper-capture.ps1" -BuildTargetOnly -OutputRoot "<large-local-test-root>"
node --test "$SkillRoot\scripts\test-win10-helper-capture-driver.cjs"
```

These checks establish compilation and diagnostic guards. The complete interactive diagnostic has not yet been executed on Windows 10; its runtime acceptance remains pending.

After explicit authorization for an interactive diagnostic, run the following in a Windows 10 guest or on the reporter's test machine. It visibly opens only the dedicated `Codex Win10 Capture Test` window. The window needs foreground focus; if initial focus was denied, the run stops rather than selecting another application.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\diagnose-win10-helper-capture.ps1" -RunCapture -OutputRoot "<large-local-test-root>"
```

Add `-HelperPath "<exact-original-helper>"` to select a preserved original explicitly. Its adjacent `@oai/sky/package.json` and official runtime JavaScript/Node files must be present. On an isolated guest without Desktop, bring that exact runtime from the development host and supply the helper path; do not use a similarly named binary or force an unsupported profile. Running the diagnostic does not require configuring a model provider or copying credentials.

`-RunCapture` compares one original cold screenshot with the patched cold screenshot, twenty static captures, four changing frames two seconds apart and three helper resource samples. Only documented baseline capture failures permit continuing from the original phase to the patched phase. It also verifies rollback of the test copy and preservation of the source helper hash. Windows 11 and Windows Server capture runs are rejected before creating output or launching a process.

The additional, explicitly selected input check clicks the target's test button using captured geometry, verifies its counter, then clicks/types into the target textbox:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\diagnose-win10-helper-capture.ps1" -RunCapture -TestInput -OutputRoot "<large-local-test-root>"
```

The driver matches the target's own HWND, process and unique title; app approval is confined to the identifier returned for that window. It stops on focus loss, stale identity, a closed target, physical Escape, unknown approval targets or capture errors. It does not retry input or reopen the target. Cleanup closes only the test process and restores only its helper copy.

## Evidence and acceptance

Each run keeps decoded images, per-phase JSON and `report.json` in its new output directory. Results contain OS/display-driver metadata, helper/frame hashes, capture times, decoded image dimensions and resource samples. Unrelated window titles, accessibility contents, stderr, credentials and the user config are not collected. Review the test-window images before sharing them, then share only the reports and reviewed images; the disposable helper homes and backups are local working files.

Visually inspect the cold/static images for the target banner and each dynamic image for changing colored panels/frame numbers. Distinct image hashes alone are insufficient. Record guest OS/graphics configuration, complete helper hashes, image inspection, requested input results, rollback and resource observations. Short resource samples do not establish a long-duration soak. `visualInspection` remains `pending` and `endToEndValidatedDesktopVersion` remains null until a reviewer attributes that missing evidence.

This external-process diagnostic exercises the official native helper path. It does not exercise Desktop's in-app approval UI, trusted Node REPL/browser channels or the separate Swift service. After native acceptance, validate any separately affected Desktop layer through its actual route before claiming it fixed. Keep the issue open until the reported Windows 10 failures have adequate runtime evidence.
