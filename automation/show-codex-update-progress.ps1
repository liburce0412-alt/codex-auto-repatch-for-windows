[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$JournalPath,
  [Parameter(Mandatory)][string]$LogRoot,
  [Parameter(Mandatory)][int]$MonitorId,
  [Parameter(Mandatory)][long]$MonitorStartTicks,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$readers = @{}
$finished = $false
$finalDrains = 0
$logBoundary = [IO.Path]::GetFullPath($LogRoot).TrimEnd('\') + '\'
function Add-ProgressLog {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($logBoundary, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetExtension($full) -ne '.log' -or $readers.ContainsKey($full)) { return }
  if (Test-Path -LiteralPath $full -PathType Leaf) {
    if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    $stream = [IO.File]::Open($full, 'Open', 'Read', 'ReadWrite, Delete')
    $readers[$full] = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
  }
}

# Translate presentation only; keep the original files and diagnostic details intact.
function ConvertTo-ChineseProgressText {
  param([string]$Text)
  $phrases = [ordered]@{
    'starting authorized scoped repair phase=Prepare'='开始已授权的补丁准备'
    'starting authorized scoped repair phase=Finalize'='开始安装后验证与配置同步'
    'authorized scoped repair phase=Prepare exited:'='补丁准备结束：'
    'authorized scoped repair phase=Finalize exited:'='安装后验证结束：'
    'exact update candidate detected:'='已检测到目标更新版本：'
    'baseline main process exited:'='更新前主进程已退出：'
    'prepared signer is already trusted in LocalMachine TrustedPeople:'='补丁签名证书已受本机信任：'
    'official recovery MSIX is unavailable; continuing under the user-approved optional-recovery policy'='未提供原版恢复包，按已授权的可选恢复包策略继续'
    'removing exact authorized Store package:'='正在替换已授权的商店包：'
    'package application data snapshot verified; removing exact current-user Store package'='应用数据备份校验通过，正在替换当前用户商店包'
    'installing validated prepared MSIX:'='正在安装已验证的补丁包：'
    'prepared MSIX install attempt failed:'='本次补丁包安装尝试失败：'
    'requesting UAC for exact validated MSIX installation only; watcher remains unelevated'='正在请求 Windows 管理员授权，仅用于安装此补丁包；监控进程保持普通权限'
    'package application data restored and hashes verified; recovery snapshot retained'='应用数据已恢复并通过完整性校验，保留状态备份'
    'exact Developer package installed independently:'='补丁包已由独立安装器安装：'
    'patched Developer process detected:'='已检测到补丁版启动进程：'
    'one-click update completed:'='更新与重补丁完成：'
    'installation complete; build files, recovery artifacts and logs retained for separately requested cleanup'='安装完成；构建文件、恢复资料和日志等待单独清理'
    'removed terminal one-click task definition:'='已移除完成的单次更新任务：'
    'selected repair source:'='已选择补丁来源：'
    'detected installed package:'='已识别安装包：'
    'selected external PowerShell:'='已选择独立 PowerShell：'
    'reusing the update backup for the pending scoped plugin retry'='复用本次更新的状态备份'
    'repair completed:'='修复完成：'
    'launching Codex Desktop with package identity and canonical executable path'='正在按已注册包身份启动 Codex'
    'prepared MSIX payload verified:'='补丁包全部文件完整性校验通过：'
    'packing MSIX:'='正在打包 MSIX：'
    'signing MSIX'='正在为补丁包签名'
    'Successfully signed:'='签名成功：'
    'patched MSIX:'='已生成补丁安装包：'
    'ASAR integrity host:'='ASAR 完整性校验宿主：'
    'asar integrity verification ok:'='ASAR 完整性校验通过：'
    'using existing signing certificate:'='复用现有签名证书：'
    'patch scope:'='补丁范围：'
    'runtime import ok:'='运行时加载及窗口枚举通过：'
    'verification ok'='校验通过'
    'repair failed:'='修复失败：'
    'start: plugin-sync-pre'='开始：安装前插件同步'
    'start: plugin-sync-post'='开始：安装后插件同步'
    'start: msix-package'='开始：构建补丁包'
    'finish: plugin-sync-pre'='结束：安装前插件同步'
    'finish: plugin-sync-post'='结束：安装后插件同步'
    'finish: msix-package'='结束：构建补丁包'
  }
  $prefix = '^(?<prefix>(?:\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+)?(?:\[[^\]\r\n]+\]\s*)?)'
  foreach ($phrase in $phrases.Keys) {
    if ($Text -match ($prefix + [regex]::Escape($phrase))) {
      return $Matches.prefix + $phrases[$phrase] + $Text.Substring($Matches[0].Length)
    }
  }
  return $Text
}
try {
  $Host.UI.RawUI.WindowTitle = 'Codex 更新 / 重补丁实时进度'
  Write-Host 'Codex 更新 / 重补丁实时进度' -ForegroundColor Cyan
  Write-Host '此窗口仅显示进度，关闭窗口不会取消后台更新。完成或失败后会保留结果。'
  Write-Host "原始日志保留在：$LogRoot"
  Write-Host '步骤：等待商店更新 → 检查/构建补丁 → 校验签名补丁包 → 安装 → 检查启动 → 清理本轮临时文件'
  $journalStream = [IO.File]::Open($JournalPath, 'Open', 'Read', 'ReadWrite, Delete')
  $journal = [IO.StreamReader]::new($journalStream, [Text.Encoding]::UTF8, $true)
  $journalPending = ''
  $followPending = @{}
  $pendingLogs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $lastHeartbeat = [datetime]::UtcNow
  do {
    $journalPending += $journal.ReadToEnd()
    while (($newline = $journalPending.IndexOf("`n")) -ge 0) {
      $line = $journalPending.Substring(0, $newline)
      $journalPending = $journalPending.Substring($newline + 1)
      if (-not $line.Trim()) { continue }
      $event = $line | ConvertFrom-Json
      switch ($event.kind) {
        'log' { Write-Host (ConvertTo-ChineseProgressText $event.text) }
        'stage' { Write-Host "`n[$($event.time)] $((ConvertTo-ChineseProgressText $event.text))" -ForegroundColor Cyan }
        'follow' { foreach ($path in $event.paths) { [void]$pendingLogs.Add($path) } }
        'done' { Write-Host "`n$((ConvertTo-ChineseProgressText $event.text))" -ForegroundColor $(if ($event.exit_code -eq 0) { 'Green' } else { 'Yellow' }); $finished = $true }
      }
    }
    foreach ($path in @($pendingLogs)) { Add-ProgressLog $path }
    foreach ($path in @($readers.Keys)) {
      $chunk = $readers[$path].ReadToEnd()
      if (-not $chunk) { continue }
      # Child repair stages publish only log locations, never commands.
      $followPending[$path] = [string]$followPending[$path] + $chunk
      while (($newline = $followPending[$path].IndexOf("`n")) -ge 0) {
        $line = $followPending[$path].Substring(0, $newline)
        $followPending[$path] = $followPending[$path].Substring($newline + 1)
        if (-not $line.StartsWith('[CODEX_PROGRESS_LOG] ')) { Write-Host (ConvertTo-ChineseProgressText $line.TrimEnd("`r")) }
        if ($line.StartsWith('[CODEX_PROGRESS_LOG] ')) {
          try { foreach ($nested in ($line.Substring(21) | ConvertFrom-Json).paths) { [void]$pendingLogs.Add($nested) } } catch { }
        }
      }
    }
    $monitor = Get-Process -Id $MonitorId -ErrorAction SilentlyContinue
    $alive = $monitor -and $monitor.StartTime.ToUniversalTime().Ticks -eq $MonitorStartTicks
    if (-not $alive -and -not $finished) {
      Write-Host "`n后台进程已结束，未收到完成确认。请查看日志：$JournalPath" -ForegroundColor Yellow
      break
    }
    if (([datetime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 15 -and -not $finished) {
      Write-Host "[$(Get-Date -Format HH:mm:ss)] 后台仍在运行，等待下一条进度…" -ForegroundColor DarkGray
      $lastHeartbeat = [datetime]::UtcNow
    }
    if ($finished) { $finalDrains++ }
    Start-Sleep -Milliseconds 300
  } while (-not $finished -or $finalDrains -lt 2)
  foreach ($pending in $followPending.Values) { if ($pending -and -not $pending.StartsWith('[CODEX_PROGRESS_LOG] ')) { Write-Host (ConvertTo-ChineseProgressText $pending) } }
} catch {
  Write-Host "进度显示失败：$($_.Exception.Message)。后台任务不受影响。日志：$JournalPath" -ForegroundColor Yellow
} finally {
  foreach ($reader in $readers.Values) { $reader.Dispose() }
  if ($journal) { $journal.Dispose() }
}
if (-not $NoPause) { [void](Read-Host '按 Enter 关闭此进度窗口') }
