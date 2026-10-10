# =============================================================================
#  安装  install.ps1
#
#  做四件事：
#    1. 校验 config.json（路径是否存在、必填项是否齐全）
#    2. 在桌面创建快捷方式：控制台 / 启动 / 停止 / 使用统计
#    3. 创建定时采样任务（token 计数需要定期采样，否则服务重启会丢数据）
#    4. 跑一次统计，确认数据管线通
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#    powershell ... -File install.ps1 -SkipTask        # 不建定时任务
#    powershell ... -File install.ps1 -Uninstall       # 卸载（删快捷方式和任务）
# =============================================================================
param([switch]$Uninstall, [switch]$SkipTask)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$Desktop = [Environment]::GetFolderPath('Desktop')
$TaskName = 'LlamaConsole-Usage-Sample'
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $Node) { $Node = 'C:\Program Files\nodejs\node.exe' }

function Say($t) { Write-Host "  $t" }

# ---------------------------------------------------------------- 卸载
if ($Uninstall) {
    Write-Host ''
    Write-Host '卸载中…'
    foreach ($n in '本地模型控制台.lnk', '启动模型.bat', '停止模型.bat', '使用统计.bat') {
        $p = Join-Path $Desktop $n
        if (Test-Path $p) { Remove-Item $p -Force; Say "已删 $n" }
    }
    schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
    Say "已删定时任务 $TaskName"
    Write-Host ''
    Write-Host '卸载完成。项目目录和 config.json 保留，删目录即可彻底清除。'
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------- 1. 校验配置
Write-Host ''
Write-Host '== 1/4 校验 config.json =='
if (-not (Test-Path $ConfigPath)) { throw "找不到 $ConfigPath" }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$exe = $cfg.llama.llamaServer
$model = $cfg.llama.model
if (-not (Test-Path $exe)) { throw "llama-server 不存在: $exe" }
Say "llama-server  $(Split-Path $exe -Leaf)"
if (-not (Test-Path $model)) { throw "模型文件不存在: $model" }
$sz = [math]::Round((Get-Item $model).Length / 1GB, 2)
Say "模型          $(Split-Path $model -Leaf)  ($sz GB)"
Say "别名 / 端口   $($cfg.llama.alias) / $($cfg.llama.port)"
Say "上下文 / 模式 $($cfg.llama.context) / $($cfg.llama.mode)"
$extra = @($cfg.llama.extraArgs)
if ($extra -notcontains '--metrics') {
    Write-Host '  [警告] extraArgs 里没有 --metrics，使用统计拿不到 token 计数。' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 2. 桌面快捷方式
Write-Host ''
Write-Host '== 2/4 创建桌面快捷方式 =='
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ws = New-Object -ComObject WScript.Shell

$lnk = $ws.CreateShortcut((Join-Path $Desktop '本地模型控制台.lnk'))
$lnk.TargetPath = $ps
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\launcher.ps1`""
$lnk.WorkingDirectory = $Root
$lnk.Description = '本地模型控制台 - 启动/停止 llama.cpp 本地模型服务'
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
$lnk.Save()
Say '本地模型控制台.lnk'

function Write-Bat($name, $body) {
    $p = Join-Path $Desktop $name
    $txt = ($body -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($p, $txt, [System.Text.Encoding]::ASCII)
    Say $name
}
Write-Bat '启动模型.bat' @"
@echo off
rem Starts the local model in a console window (no GUI). Ctrl+C to stop.
chcp 65001 >nul
title Local Model Server
"$exe" -m "$model" -c $($cfg.llama.context) -ngl $($cfg.llama.gpuLayers) -t $($cfg.llama.threads) -b $($cfg.llama.batch) -ub $($cfg.llama.ubatch) --host $($cfg.llama.host) --port $($cfg.llama.port) --alias $($cfg.llama.alias) $(@($cfg.llama.extraArgs) -join ' ')
pause
"@
Write-Bat '停止模型.bat' @"
@echo off
title Stop Local Model
taskkill /IM llama-server.exe /F >nul 2>&1
if errorlevel 1 (echo No llama-server.exe process found.) else (echo Stopped.)
ping -n 3 127.0.0.1 >nul
"@
Write-Bat '使用统计.bat' @"
@echo off
rem chcp 65001 is required: the tracker prints UTF-8 Chinese.
chcp 65001 >nul
title Usage Statistics
"$Node" "$Root\usage\track.mjs" %*
echo.
pause
"@

# ---------------------------------------------------------------- 3. 定时采样
Write-Host ''
Write-Host '== 3/4 定时采样任务 =='
if ($SkipTask) {
    Say '已跳过（-SkipTask）'
} else {
    $Interval = if ($cfg.usage.sampleIntervalMinutes) { [int]$cfg.usage.sampleIntervalMinutes } else { 10 }
    $sampleBat = Join-Path $Root 'usage\sample.bat'
    [System.IO.File]::WriteAllText($sampleBat, "@echo off`r`n`"$Node`" `"$Root\usage\track.mjs`" --quiet`r`n", [System.Text.Encoding]::ASCII)
    Say "sample.bat 已写"
    schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
    $out = schtasks /create /tn $TaskName /tr "$sampleBat" /sc minute /mo $Interval /f 2>&1
    if ($LASTEXITCODE -eq 0) { Say "定时任务 $TaskName 已建（每 $Interval 分钟）" }
    else { Write-Host "  建任务失败：$out" -ForegroundColor Yellow; Say '可以手动跑「使用统计.bat」，只是服务重启时可能丢一段 token。' }
}

# ---------------------------------------------------------------- 4. 跑一次
Write-Host ''
Write-Host '== 4/4 首次统计 =='
& $Node (Join-Path $Root 'usage\track.mjs') 2>&1 | Select-Object -First 22 | ForEach-Object { Write-Host "  $_" }

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class ShellRefresh {
  [DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);
  public static void Go() { SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
}
"@
[ShellRefresh]::Go()

Write-Host ''
Write-Host '安装完成。桌面已生成 4 个入口，双击「本地模型控制台」即可。'
Write-Host "卸载：powershell -File `"$Root\install.ps1`" -Uninstall"
Write-Host ''
