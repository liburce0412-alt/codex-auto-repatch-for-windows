[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$JournalPath,
  [Parameter(Mandatory)][string]$LogRoot,
  [Parameter(Mandatory)][int]$MonitorId,
  [Parameter(Mandatory)][long]$MonitorStartTicks,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
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

try {
  $Host.UI.RawUI.WindowTitle = 'Codex 更新 / 重补丁实时进度'
  Write-Host 'Codex 更新 / 重补丁实时进度' -ForegroundColor Cyan
  Write-Host '此窗口仅显示进度，关闭窗口不会取消后台更新。完成或失败后会保留结果。'
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
        'log' { Write-Host $event.text }
        'stage' { Write-Host "`n[$($event.time)] $($event.text)" -ForegroundColor Cyan }
        'follow' { foreach ($path in $event.paths) { [void]$pendingLogs.Add($path) } }
        'done' { Write-Host "`n$($event.text)" -ForegroundColor $(if ($event.exit_code -eq 0) { 'Green' } else { 'Yellow' }); $finished = $true }
      }
    }
    foreach ($path in @($pendingLogs)) { Add-ProgressLog $path }
    foreach ($path in @($readers.Keys)) {
      $chunk = $readers[$path].ReadToEnd()
      if (-not $chunk) { continue }
      Write-Host $chunk -NoNewline
      # Child repair stages publish only log locations, never commands.
      $followPending[$path] = [string]$followPending[$path] + $chunk
      while (($newline = $followPending[$path].IndexOf("`n")) -ge 0) {
        $line = $followPending[$path].Substring(0, $newline)
        $followPending[$path] = $followPending[$path].Substring($newline + 1)
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
} catch {
  Write-Host "进度显示失败：$($_.Exception.Message)。后台任务不受影响。日志：$JournalPath" -ForegroundColor Yellow
} finally {
  foreach ($reader in $readers.Values) { $reader.Dispose() }
  if ($journal) { $journal.Dispose() }
}
if (-not $NoPause) { [void](Read-Host '按 Enter 关闭此进度窗口') }
