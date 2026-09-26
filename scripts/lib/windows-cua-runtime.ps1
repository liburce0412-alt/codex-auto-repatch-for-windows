function Repair-WindowsCuaEntryInstructions {
  param(
    [Parameter(Mandatory = $true)]
    [string]$NodeModulesRoot,
    [string]$BackupRoot,
    [switch]$VerifyOnly
  )

  $path = Join-Path $NodeModulesRoot '@oai\cua-repl\instructions\windows\computer.md'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return 'not-applicable'
  }

  $before = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
  $original = @'
If the user specifies an app to use, get the app by name, bundle ID, or path:

```javascript
let app = await cua.getApp("Example App");
```
'@
  $replacement = @'
For a Windows app, first list open windows and select the one whose app and title match the task:

```javascript
await cua.listWindows();
```

Bind the exact window ID returned by that inventory:

```javascript
let app = await cua.getApp({ windowId: windowIdFromInventory });
```

On Windows, getApp does not launch apps or accept an app name, bundle ID, or executable path. If the app has no open window, call cua.listApps(), launch its returned inventory ID with cua.computer.launch_app({ app: appId }), then refresh cua.listWindows().

Before judging a screenshot, bring the target forward with its exposed Raise secondary action and inspect the image content together with the current accessibility state.
'@
  $original = $original.Replace("`r`n", "`n").TrimEnd()
  $replacement = $replacement.Replace("`r`n", "`n").TrimEnd() + "`n"
  if ($before -ceq $replacement) {
    return 'already-patched'
  }
  if ($before.Contains('cua.getApp({ windowId:') -and $before.Contains('cua.listWindows()')) {
    return 'already-correct'
  }
  if ($before.TrimEnd() -cne $original) {
    throw "unrecognized Windows CUA entry instructions; left unchanged: $path"
  }
  if ($VerifyOnly) {
    throw "Windows CUA entry instructions still recommend the unsupported app-name binding: $path"
  }

  if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
      $digest = [BitConverter]::ToString($hash.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-', '')
    } finally {
      $hash.Dispose()
    }
    $backupDirectory = Join-Path $BackupRoot $digest
    $backupPath = Join-Path $backupDirectory 'computer.md.original'
    New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
      if ([IO.File]::ReadAllText($backupPath).Replace("`r`n", "`n") -cne $before) {
        throw "existing Windows CUA instructions backup does not match: $backupPath"
      }
    } else {
      Copy-Item -LiteralPath $path -Destination $backupPath
    }
  }

  [IO.File]::WriteAllText($path, $replacement, [Text.UTF8Encoding]::new($false))
  if ([IO.File]::ReadAllText($path) -cne $replacement) {
    throw "Windows CUA entry instructions write verification failed: $path"
  }
  return 'patched'
}

function Repair-StagedWindowsComputerUseHelper {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HelperPath,
    [Parameter(Mandatory = $true)]
    [string]$PatcherPath,
    [Parameter(Mandatory = $true)]
    [string]$BackupRoot,
    [switch]$PatchRequested
  )

  if (-not $PatchRequested) {
    return 'skipped-not-requested'
  }
  if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    return 'not-applicable'
  }
  $before = @(& $PatcherPath -HelperPath $HelperPath -CodexHome $BackupRoot) | Select-Object -Last 1
  if ($before.WindowsBuild -ge 22000) {
    return 'not-applicable'
  }
  if ($before.State -notin @('original-patchable', 'patched')) {
    throw "unsupported staged Windows 10 helper SHA-256: $($before.Sha256)"
  }

  # The existing patcher owns the full hash, version, region and backup checks.
  & $PatcherPath -HelperPath $HelperPath -CodexHome $BackupRoot -Install | Out-Host
  $after = @(& $PatcherPath -HelperPath $HelperPath -CodexHome $BackupRoot) | Select-Object -Last 1
  if ($after.State -ne 'patched') {
    throw "staged Windows 10 helper is not patched: $HelperPath"
  }
  if ($before.State -eq 'patched') {
    return 'already-patched'
  }
  return 'patched'
}
