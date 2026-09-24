param([Parameter(Mandatory)][string]$CliPath,
  [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$CliSha256,
  [string]$Reason, [string]$LogPath)
$ErrorActionPreference='Stop'
$Host.UI.RawUI.WindowTitle='Codex CLI — 桌面补丁失败后的备用入口'
Write-Host '桌面重补丁未完成，已切换到 Codex CLI。' -ForegroundColor Yellow
Write-Host "原因：$Reason"
Write-Host "更新日志：$LogPath"
Write-Host '沿用你的现有 Codex 配置；不会自动发送任务或更改模型。'
if ((Get-FileHash -LiteralPath $CliPath -Algorithm SHA256).Hash -ne $CliSha256) { throw 'CLI changed before launch' }
Set-Location -LiteralPath $env:USERPROFILE
& $CliPath
Write-Host "Codex CLI 已退出（$LASTEXITCODE），可以在此终端继续操作。"
