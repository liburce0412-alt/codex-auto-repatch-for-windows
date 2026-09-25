# Codex 自动化重补丁 for Windows

[English](README.en.md)

Windows 商店更新 Codex Desktop 后，自动重新应用已适配的本地补丁，显示实时终端进度；修复失败时打开独立 Codex CLI，保留日志和应用数据备份。项目由 [liburce0412-alt](https://github.com/liburce0412-alt) 维护。

## 这个版本做什么

- **更新后自动修复**：监听 Windows AppX 商店注册事件，并在登录后补查；无需常驻轮询进程。
- **实时进度**：单独终端显示准备、打包、安装、重启等阶段及实际子进程日志；关闭查看窗口不会终止任务。
- **失败转到 CLI**：提前从当前安装包复制并校验独立 CLI 和运行组件，失败后打开一次交互终端，沿用现有模型与配置，不自动发送任务。
- **先备份再替换**：校验补丁包身份、版本、签名和哈希，备份应用数据后才卸载当前用户的精确商店包。原版 MSIX 恢复包是可选项。
- **成功后清理**：安装、后处理和窗口稳定检查通过后，按清单和哈希清理本轮构建，以及历史失败安装残留、旧恢复副本和不再使用的旧版 CLI；保留当前版本、最新恢复包与数据备份、诊断记录。正在使用、版本不明、较新或内容变化的目录会保留或延后处理。
- **失败版本不循环重试**：修正问题后可显式重试同一版本；后续新商店版本重新检查兼容性。

默认自动化范围是 Chrome/Browser、Windows Computer Use 与自定义模型可见性。仓库也保留手动修复工具，具体适用范围见 [SKILL.md](SKILL.md)。未知代码结构会中止打包，不承诺所有未来版本通用。

下次按默认范围或完整范围重打包时，会一并加入浏览器数据导入异常日志。导入失败时可查找 `Browser profile import exception`，错误走现有敏感日志通道，不额外记录导入请求或结果。此改动只帮助定位 Cookie 导入失败，不代表已修复；更新脚本文件本身不会触发安装或重启。

## 安装

需要 Windows x64、当前用户已安装的 Codex Desktop、Git，以及**独立安装的 PowerShell 7.5 或以上**。构建工具由现有补丁脚本检查；首次打包可能需要下载 Windows SDK。请预留安装包展开和应用数据备份的磁盘空间。

在外部 PowerShell 窗口中执行。首次克隆时请使用以下目录；已有安装请先保存本地改动，不要覆盖或强制重置。

```powershell
git clone https://github.com/liburce0412-alt/codex-auto-repatch-for-windows.git "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"
Set-Location "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"
pwsh.exe -NoProfile -File .\scripts\install-update-automation.ps1 -EnableAutomation
```

`-EnableAutomation` 为当前用户创建长期更新授权，注册任务计划 `Codex Desktop Post-Update Repair`，允许商店更新后自动关闭并修复 Codex。安装脚本会备份旧脚本，部署自动化组件并验证独立 CLI。它不会立即执行重补丁。

目录名保留 `codex-windows-fast-patch`，用于兼容技能识别和现有自动化路径；仓库展示名与此不同。

## 使用与维护

更新 Codex 后，任务会检查商店版本；识别到适配目标才进入准备、安装及验证。实时进度终端会显示日志，安装需要权限时可能出现仅针对已验证 MSIX 的 UAC 提示。

查看状态：

```powershell
Get-ScheduledTask -TaskName 'Codex Desktop Post-Update Repair'
Get-Content "$env:USERPROFILE\.codex\automation\update-cycle-active.json" -Raw
```

修复失败原因后，显式重试当前商店版本（会关闭 Codex，请在外部 PowerShell 运行）：

```powershell
$root = Join-Path $env:USERPROFILE '.codex\automation'
$authorization = Get-Content (Join-Path $root 'standing-update-authorization.json') -Raw | ConvertFrom-Json
& (Join-Path $root 'invoke-codex-standing-update.ps1') -StandingAuthorizationId $authorization.authorization_id -RetryFailedVersion
```

更新仓库代码并检查差异后，重新部署脚本，不更改现有授权：

```powershell
pwsh.exe -NoProfile -File .\scripts\install-update-automation.ps1
```

本 fork 不在调用技能或补丁失败时自动同步上游。代码更新应显式进行，保留自己的本地修改。

暂停未来自动运行：

```powershell
Disable-ScheduledTask -TaskName 'Codex Desktop Post-Update Repair'
```

此命令不终止正在执行的安装。不要在包部署过程中直接杀死安装进程。

## 失败、恢复与清理

独立 CLI 位于 `%LOCALAPPDATA%\OpenAI\Codex\bin\post-update-<版本>`，不依赖卸载后消失的 WindowsApps 路径。自动打开终端只代表 CLI 入口可用，不代表网络或模型请求成功。

商店包替换后若安装失败，桌面版可能暂时不可用，流程会打开 CLI，不会自动回装商店版。可以随后通过 Microsoft Store 重新安装桌面版。原版恢复安装包无需预先准备；**应用数据备份仍然必需**。

应用数据位于其他 AppX 卷且带有 EFS 加密属性时，普通文件复制可能报“无法加密指定的文件”。备份和恢复现使用文件流复制内容，保留哈希与目录边界校验；备份失败仍会阻止卸载。遇到此错误后，先更新并重新部署自动化脚本，再按上文显式重试。详见 [加密文件备份案例](references/local-post-update-safety.md#encrypted-application-data-2026-09-24)。

本机运行数据在 `%USERPROFILE%\.codex\automation`：

| 位置 | 用途 |
| --- | --- |
| `logs` | 阶段进度、子进程输出和失败原因 |
| `install-handoffs\<运行ID>\appdata-backup` | 保留最新成功安装的恢复备份；后续安装成功且稳定后，旧运行目录才可按清单清理 |
| `install-handoffs\<运行ID>\build` | 本次构建缓存，仅稳定成功后按清单删除 |
| `install-handoffs\<运行ID>` | 签名补丁包和安装交接记录 |
| `store-recovery\<版本>\original.msix` | 可选的原版签名商店包 |

不上传这些目录、授权 JSON、凭据、日志或安装包。更多边界见 [自动更新与清理说明](references/local-post-update-safety.md)。

## 验证状态

2026-09-25 在 26.917.9434.0 上，通过仅向 Codex 进程传入本机代理启动，实际验证了 Chrome 会话、标签页读取、公开网页导航、链接点击和返回。不要把 Electron 主进程的代理设置等同于原生 Chrome 控制辅助进程已继承代理；当前补丁只转发主进程已有的代理环境变量。此结果不代表 Cookie 导入已修复。

已为 26.917 系列集成 CUA readiness 适配、旧补丁迁移和代理环境传递。2026-09-24 在本机完成了 26.917.8451.0 的真实安装：加密文件备份修复后，应用数据备份与恢复哈希校验、Developer 包安装、重启稳定检查及构建清理均通过；已安装 ASAR 与验证过的补丁包一致，插件及运行时检查、窗口枚举通过。该次安装没有验证 Chrome 实际网页操作，这些结果也不代表所有机器或未来版本均兼容。自动化测试仍使用隔离文件与模拟部署命令，不会卸载当前应用。

```powershell
pwsh.exe -NoProfile -File .\automation\tests\test-update-safety.ps1
pwsh.exe -NoProfile -File .\automation\tests\test-appdata-backup.ps1
pwsh.exe -NoProfile -File .\automation\tests\test-update-progress.ps1
pwsh.exe -NoProfile -File .\automation\tests\test-superseded-watcher.ps1
pwsh.exe -NoProfile -File .\scripts\test-computer-use-surface-patterns.ps1 -TemporaryRoot "$env:TEMP\codex-auto-repatch-tests"
```

## 来源

此项目是 [chen0416ccc-cpu/codex-windows-fast-patch-skill](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill) 的派生项目，保留其补丁工具与 Git 历史，并整合适用的社区修复。本 README 为本 fork 重写，自动化更新、CLI 回退和清理流程以本仓库实现为准。此项目不是 OpenAI 官方项目。
