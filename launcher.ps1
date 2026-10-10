# =============================================================================
#  本地模型控制台  launcher.ps1
#
#  图形界面启动器：管理 llama.cpp 本地模型服务。
#  所有可配置项都在同目录的 config.json 里 —— 本文件不需要改。
#
#  依赖：Windows 自带 .NET WinForms，无需安装任何东西。
#  用法：由 install.ps1 创建桌面快捷方式，或直接
#        powershell -NoProfile -ExecutionPolicy Bypass -File launcher.ps1
# =============================================================================

param([switch]$PrintArgs, [switch]$CheckConfig)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$UsageDir = Join-Path $Root 'usage'
$UsageFile = Join-Path $UsageDir 'usage.json'
$LogFile = Join-Path $Root 'server.log'
$ErrFile = Join-Path $Root 'server.err.log'

# ---------------------------------------------------------------- 读配置
function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "找不到配置文件: $ConfigPath" }
    $c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $l = $c.llama
    if (-not $l) { throw 'config.json 缺少 llama 段' }
    if (-not $l.llamaServer) { throw 'config.json 缺少 llama.llamaServer' }
    if (-not $l.model) { throw 'config.json 缺少 llama.model' }

    $modeName = if ($l.mode) { $l.mode } else { 'translate' }
    $mode = $l.modes.$modeName
    if (-not $mode) {
        $first = @($l.modes.PSObject.Properties)[0]
        $modeName = $first.Name
        $mode = $first.Value
    }

    $u = $c.usage
    return [pscustomobject]@{
        Title       = if ($c.ui.title) { $c.ui.title } else { '本地模型控制台' }
        Width       = if ($c.ui.windowWidth) { [int]$c.ui.windowWidth } else { 720 }
        Height      = if ($c.ui.windowHeight) { [int]$c.ui.windowHeight } else { 620 }
        Exe         = $l.llamaServer
        Model       = $l.model
        DisplayName = if ($l.displayName) { $l.displayName } else { Split-Path $l.model -Leaf }
        Alias       = if ($l.alias) { $l.alias } else { 'local-model' }
        Host_       = if ($l.host) { $l.host } else { '127.0.0.1' }
        Port        = if ($l.port) { [int]$l.port } else { 8090 }
        Context     = if ($l.context) { [int]$l.context } else { 32768 }
        Threads     = if ($l.threads) { [int]$l.threads } else { 8 }
        Batch       = if ($l.batch) { [int]$l.batch } else { 1024 }
        Ubatch      = if ($l.ubatch) { [int]$l.ubatch } else { 512 }
        GpuLayers   = if ($l.gpuLayers) { [int]$l.gpuLayers } else { 999 }
        ModeName    = $modeName
        Mode        = $mode
        ExtraArgs   = @($l.extraArgs)
        UsageOn     = if ($null -ne $u.enabled) { [bool]$u.enabled } else { $true }
        DshHome     = if ($u.dshHome) { $u.dshHome } else { '' }
        DshPort     = if ($u.dshWebPort) { [int]$u.dshWebPort } else { 3080 }
    }
}

function Build-ArgString($C) {
    $m = $C.Mode
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add("-m"); $a.Add('"' + $C.Model + '"')
    $a.Add('-c'); $a.Add($C.Context)
    $a.Add('-ngl'); $a.Add($C.GpuLayers)
    $a.Add('-t'); $a.Add($C.Threads)
    $a.Add('-b'); $a.Add($C.Batch)
    $a.Add('-ub'); $a.Add($C.Ubatch)
    $a.Add('--host'); $a.Add($C.Host_)
    $a.Add('--port'); $a.Add($C.Port)
    $a.Add('--alias'); $a.Add($C.Alias)
    $a.Add('--temp'); $a.Add($m.temp)
    $a.Add('--top-k'); $a.Add($m.topK)
    $a.Add('--top-p'); $a.Add($m.topP)
    $a.Add('--min-p'); $a.Add($m.minP)
    $a.Add('--repeat-penalty'); $a.Add($m.repeatPenalty)
    $a.Add('--presence-penalty'); $a.Add($m.presencePenalty)
    $a.Add('--frequency-penalty'); $a.Add($m.frequencyPenalty)
    $a.Add('--dry-multiplier'); $a.Add($m.dryMultiplier)
    foreach ($x in $C.ExtraArgs) { if ($null -ne $x -and "$x" -ne '') { $a.Add("$x") } }
    return ($a -join ' ')
}

# ---------------------------------------------------------------- 小工具
function Test-PortListening([int]$Port) {
    try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) }
    catch { return $false }
}
function Get-ModelProcess { return Get-Process llama-server -ErrorAction SilentlyContinue }
function Get-GpuMemory {
    try {
        $line = (& nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>$null) | Select-Object -First 1
        if ($line -match '(\d+)\s*MiB,\s*(\d+)\s*MiB') { return @{ Used = [int]$Matches[1]; Total = [int]$Matches[2] } }
    } catch { }
    return $null
}
function Format-Dur([object]$Seconds) {
    $s = [Math]::Round([double]$Seconds)
    if ($s -lt 60) { return "$s 秒" }
    $h = [Math]::Floor($s / 3600); $m = [Math]::Floor(($s % 3600) / 60)
    if ($h -eq 0) { return "$m 分" }
    return "$h 时 $m 分"
}
function Format-Tok([object]$N) {
    $n = [double]$N
    if ($n -ge 1000000) { return ('{0:N1}M token' -f ($n / 1000000)) }
    if ($n -ge 1000) { return ('{0:N1}k token' -f ($n / 1000)) }
    return ('{0} token' -f [Math]::Round($n))
}
function Get-LogTail([string]$Path, [int]$Lines = 40) {
    if (-not (Test-Path $Path)) { return '' }
    try { return ((Get-Content $Path -Tail $Lines -ErrorAction Stop) -join "`r`n") } catch { return '' }
}
function Get-UsageText([string]$Path) {
    if (-not (Test-Path $Path)) { return "使用统计`r`n(还没有数据。跑一次 install.ps1 或 usage\track.mjs)" }
    $u = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    $today = $null
    try { $today = $u.days.PSObject.Properties[$u.today].Value } catch { }
    if ($null -eq $today) { $today = @($u.days.PSObject.Properties)[-1].Value }
    $sum = @{ a = 0.0; w = 0.0; g = 0.0; p = 0.0; c = 0.0 }
    foreach ($prop in $u.days.PSObject.Properties) {
        $v = $prop.Value
        $sum.a += [double]$v.sessionActiveSeconds
        $sum.w += [double]$v.sessionWorkSeconds
        $sum.g += [double]$v.localGeneratedTokens
        $sum.p += [double]$v.localPromptTokens
        $sum.c += [double]$v.deepseekCny
    }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('使用统计               今日 / 累计')
    $out.Add('使用时长      ' + (Format-Dur $today.sessionActiveSeconds) + ' / ' + (Format-Dur $sum.a))
    $out.Add('整机工时      ' + (Format-Dur $today.sessionWorkSeconds) + ' / ' + (Format-Dur $sum.w))
    $out.Add('本地生成      ' + (Format-Tok $today.localGeneratedTokens) + ' / ' + (Format-Tok $sum.g))
    $out.Add('本地提示      ' + (Format-Tok $today.localPromptTokens) + ' / ' + (Format-Tok $sum.p))
    if ($sum.c -gt 0) {
        $out.Add('云端花费      ' + [char]0xA5 + ('{0:N2}' -f [double]$today.deepseekCny) + ' / ' + [char]0xA5 + ('{0:N2}' -f $sum.c))
    }
    return ($out -join "`r`n")
}

# ---------------------------------------------------------------- 读配置 + 建窗口
$CONFIG = Read-Config
$script:serverArgs = Build-ArgString $CONFIG

# 自检模式：不开窗口，只打印解析结果，方便排查配置问题
if ($CheckConfig -or $PrintArgs) {
    Write-Host "配置文件   : $ConfigPath"
    Write-Host "llama-server: $($CONFIG.Exe)   [$(if (Test-Path $CONFIG.Exe) { '存在' } else { '找不到' })]"
    Write-Host "模型        : $($CONFIG.Model)  [$(if (Test-Path $CONFIG.Model) { '存在' } else { '找不到' })]"
    Write-Host "别名 / 端口 : $($CONFIG.Alias) / $($CONFIG.Port)"
    Write-Host "上下文/线程 : $($CONFIG.Context) / $($CONFIG.Threads)"
    Write-Host "采样模式    : $($CONFIG.ModeName)"
    Write-Host "统计开关    : $($CONFIG.UsageOn)"
    if ($PrintArgs) {
        Write-Host ''
        Write-Host '实际启动参数：'
        Write-Host "  `"$($CONFIG.Exe)`" $($script:serverArgs)"
    }
    exit 0
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $CONFIG.Title
$form.Size = New-Object System.Drawing.Size($CONFIG.Width, $CONFIG.Height)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

function New-Label($text, $x, $y, $w, $h, $size = 9, $bold = $false, $color = $null) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $size, $style)
    if ($color) { $l.ForeColor = $color }
    $form.Controls.Add($l)
    return $l
}
function New-Button($text, $x, $y, $w, $h, $onClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'
    $b.BackColor = [System.Drawing.Color]::FromArgb(58, 58, 66)
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
    $b.Cursor = 'Hand'
    $b.Add_Click($onClick)
    $form.Controls.Add($b)
    return $b
}

$GREEN = [System.Drawing.Color]::FromArgb(80, 220, 120)
$YELLOW = [System.Drawing.Color]::FromArgb(240, 190, 70)
$RED = [System.Drawing.Color]::FromArgb(200, 80, 80)
$GREY = [System.Drawing.Color]::FromArgb(160, 160, 170)

$lblDot = New-Label '●' 24 18 24 24 16 $true ([System.Drawing.Color]::Gray)
$lblStatus = New-Label '正在检测…' 54 20 300 24 11 $true
$lblPort = New-Label '' 380 22 300 22 9 $false $GREY

$lblModel = New-Label ("模型：" + $CONFIG.DisplayName) 24 52 460 20
$lblAlias = New-Label ("别名：" + $CONFIG.Alias) 24 74 460 20
$lblVram = New-Label '显存：—' 24 96 460 20
$lblConf = New-Label ("配置：" + $CONFIG.Context + " 上下文 · " + $CONFIG.ModeName + " 模式") 24 118 500 20
$lblApi = New-Label ("接口：http://" + $CONFIG.Host_ + ":" + $CONFIG.Port + "/v1") 24 140 500 20

# ---------------------------------------------------------------- 日志区先声明（按钮要用）
$txtLog = New-Object System.Windows.Forms.TextBox
function Append-Log([string]$Text) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    $txtLog.AppendText("[$ts] $Text`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
}

function Start-Model {
    if (Test-PortListening $CONFIG.Port) { Append-Log "端口 $($CONFIG.Port) 已被占用，服务应已在运行。"; return }
    if (-not (Test-Path $CONFIG.Exe)) { Append-Log "找不到 llama-server：$($CONFIG.Exe)"; return }
    if (-not (Test-Path $CONFIG.Model)) { Append-Log "找不到模型文件：$($CONFIG.Model)"; return }
    Append-Log "启动中（$($CONFIG.ModeName) 模式，$($CONFIG.Context) 上下文）…"
    Remove-Item $LogFile, $ErrFile -ErrorAction SilentlyContinue
    Start-Process -FilePath $CONFIG.Exe -ArgumentList $script:serverArgs `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogFile -RedirectStandardError $ErrFile | Out-Null
    $script:waitTicks = 1
}

$btnStart = New-Button '启动模型' 24 168 120 38 { Start-Model }
$btnStop = New-Button '停止模型' 154 168 120 38 {
    $p = Get-ModelProcess
    if (-not $p) { Append-Log '没有正在运行的模型进程。'; return }
    Append-Log "正在停止（PID $(($p | ForEach-Object { $_.Id }) -join ',')）…"
    $p | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    Append-Log $(if (Get-ModelProcess) { '停止失败，请手动检查。' } else { '已停止。' })
}
$btnRestart = New-Button '重启模型' 284 168 120 38 {
    $p = Get-ModelProcess
    if ($p) { $p | Stop-Process -Force; Start-Sleep -Milliseconds 900 }
    Start-Model
}
$btnChat = New-Button '打开对话界面' 414 168 120 38 { Start-Process ("http://" + $CONFIG.Host_ + ":" + $CONFIG.Port + '/ui') }
$btnApi = New-Button 'API 文档' 544 168 120 38 { Start-Process ("http://" + $CONFIG.Host_ + ":" + $CONFIG.Port + '/v1/models') }

$lblUsage = New-Label '' 24 214 656 86 8.5 $false ([System.Drawing.Color]::FromArgb(150, 200, 235))

New-Label '运行日志' 24 304 100 22 10 $true | Out-Null
$txtLog.Location = New-Object System.Drawing.Point(24, 328)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 24)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(190, 220, 190)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtLog.WordWrap = $false
$txtLog.BorderStyle = 'FixedSingle'
$form.Controls.Add($txtLog)
$txtLog.Size = New-Object System.Drawing.Size(656, 242)

# ---------------------------------------------------------------- 状态刷新
$script:waitTicks = 0
$script:lastLogLen = 0
$script:usageTick = 0

function Update-Status {
    $running = (Test-PortListening $CONFIG.Port) -and (Get-ModelProcess)

    if ($running) {
        $lblDot.ForeColor = $GREEN; $lblStatus.Text = '运行中'; $lblStatus.ForeColor = $GREEN
    } elseif ($script:waitTicks -gt 0 -and $script:waitTicks -lt 40) {
        $lblDot.ForeColor = $YELLOW; $lblStatus.Text = '启动中…'; $lblStatus.ForeColor = $YELLOW
        $script:waitTicks++
    } else {
        $lblDot.ForeColor = $RED; $lblStatus.Text = '已停止'; $lblStatus.ForeColor = $RED
        $script:waitTicks = 0
    }
    $lblPort.Text = if ($running) { "端口 $($CONFIG.Port) 正在监听" } else { "端口 $($CONFIG.Port) 空闲" }

    $g = Get-GpuMemory
    $lblVram.Text = if ($g) { "显存：$($g.Used) / $($g.Total) MiB" } else { '显存：读取失败' }

    if ($CONFIG.UsageOn) {
        $script:usageTick++
        if ($script:usageTick -ge 15 -or $script:usageTick -eq 1) {
            $script:usageTick = 1
            try { $lblUsage.Text = Get-UsageText $UsageFile }
            catch { $lblUsage.Text = "使用统计`r`n读取失败: $($_.Exception.Message)" }
        }
    } else {
        $lblUsage.Text = '使用统计已关闭（config.json → usage.enabled）'
    }

    if ($env:LLAMA_CONSOLE_DUMP) {
        $script:dumps = 1 + [int]$script:dumps
        if ($script:dumps -eq 3) {
            $lines = @()
            foreach ($c in $form.Controls) {
                $lines += ("{0,-10} loc=({1},{2}) size={3}x{4} text=[{5}]" -f $c.GetType().Name, $c.Location.X, $c.Location.Y, $c.Size.Width, $c.Size.Height, $c.Text)
            }
            [System.IO.File]::WriteAllLines($env:LLAMA_CONSOLE_DUMP, $lines, (New-Object System.Text.UTF8Encoding($true)))
        }
    }

    $tail = Get-LogTail $LogFile 40
    if ($tail.Length -gt 0 -and $tail.Length -ne $script:lastLogLen) {
        $script:lastLogLen = $tail.Length
        $txtLog.Text = $tail
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
    if ($tail.Length -eq 0) {
        $e = Get-LogTail $ErrFile 25
        if ($e.Length -gt 0 -and $e.Length -ne $script:lastLogLen) {
            $script:lastLogLen = $e.Length
            $txtLog.Text = $e
            $txtLog.SelectionStart = $txtLog.Text.Length
            $txtLog.ScrollToCaret()
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })
$timer.Start()

$form.Add_Shown({
    Append-Log '控制台已就绪。'
    Append-Log "模型 $($CONFIG.DisplayName)　别名 $($CONFIG.Alias)　端口 $($CONFIG.Port)　$($CONFIG.ModeName) 模式"
    Update-Status
})

[void]$form.ShowDialog()
$timer.Stop()
