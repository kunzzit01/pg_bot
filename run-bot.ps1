param([switch]$NoPause)

# ==================================================================
#  Telegram Bot 本地测试启动器 + 最近30行滚动错误监控
#  用法:  powershell -ExecutionPolicy Bypass -File run-bot.ps1
#         或直接双击同目录的 启动测试.bat
# ==================================================================

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 | Out-Null } catch {}
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUNBUFFERED = "1"

Set-Location -Path $PSScriptRoot

$RING_SIZE = 30
$script:errCount = 0
$script:warnCount = 0
$script:conflictHinted = $false
$script:lastAlertAt = Get-Date "2000-01-01"
$ring = New-Object System.Collections.Generic.List[string]

# 异常指标：Traceback / ERROR / Exception / CRITICAL / FATAL / Failed / Conflict
$errRegex  = '(?i)(traceback|\berror\b|exception|critical|\bfatal\b|failed|conflict)'
$warnRegex = '(?i)warning'

function Write-Box([string]$text, [string]$color = "Green") {
    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor $color
    Write-Host $text -ForegroundColor $color
    Write-Host ("=" * 62) -ForegroundColor $color
}

function Show-AlertBanner {
    # 5秒内只弹一次横幅，避免刷屏
    $now = Get-Date
    if (($now - $script:lastAlertAt).TotalSeconds -lt 5) { return }
    $script:lastAlertAt = $now
    try { [Console]::Beep(880, 250) } catch {}
    Write-Host ""
    Write-Host ("[!!] 异常指标提示：最近{0}行内 累计异常 {1} 个 / 警告 {2} 个" -f $RING_SIZE, $script:errCount, $script:warnCount) -ForegroundColor Red
    Write-Host "     ---- 最近输出（末5行）----" -ForegroundColor DarkRed
    $ring | Select-Object -Last 5 | ForEach-Object { Write-Host ("     | " + $_) -ForegroundColor DarkRed }
}

# ---------- 1. 虚拟环境 ----------
$venvPython = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    Write-Host "首次运行：创建虚拟环境（约10秒）..."
    & py -3 -m venv .venv 2>&1 | Out-Null
    if (-not (Test-Path $venvPython)) {
        Write-Host "[X] 创建虚拟环境失败：请确认已安装 Python 3（含 py 启动器）" -ForegroundColor Red
        if (-not $NoPause) { try { [void](Read-Host "按回车关闭") } catch {} }
        exit 1
    }
}

# ---------- 2. 依赖 ----------
& $venvPython -c "import telegram, apscheduler, openpyxl" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "首次运行：安装依赖 python-telegram-bot[job-queue] + openpyxl（约1分钟）..."
    & $venvPython -m pip install --disable-pip-version-check -q "python-telegram-bot[job-queue]" openpyxl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] 依赖安装失败，请检查网络后重试" -ForegroundColor Red
        if (-not $NoPause) { try { [void](Read-Host "按回车关闭") } catch {} }
        exit 1
    }
}

# ---------- 3. 数据目录 + 日志文件 ----------
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot "data") | Out-Null
$logFile = Join-Path $PSScriptRoot ("bot-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$startTime = Get-Date

Write-Box ("Telegram Bot 本地测试 | 监控: 最近{0}行滚动错误检测 | 日志: {1}" -f $RING_SIZE, (Split-Path $logFile -Leaf)) "Cyan"
Write-Host "停止测试: Ctrl+C    异常输出将以红色高亮 + 提示音标出" -ForegroundColor DarkCyan
Write-Host ""

# ---------- 4. 运行 + 实时监控 ----------
$exitCode = -1
try {
    & $venvPython -u ".\bot.py" 2>&1 | ForEach-Object {
        $line = "$_"
        $stamp = Get-Date -Format "HH:mm:ss"
        try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
        $ring.Add($line)
        if ($ring.Count -gt $RING_SIZE) { $ring.RemoveAt(0) }

        if ($line -match '(?i)conflict') {
            $script:errCount++
            Write-Host "[$stamp] $line" -ForegroundColor Red
            if (-not $script:conflictHinted) {
                $script:conflictHinted = $true
                Write-Host "[!!] getUpdates 冲突：同一个 Bot Token 被两个程序同时使用（例如 VPS 上也启动了本机器人）。请只保留一个实例。" -ForegroundColor Yellow
            }
            Show-AlertBanner
        }
        elseif ($line -match $errRegex) {
            $script:errCount++
            Write-Host "[$stamp] $line" -ForegroundColor Red
            Show-AlertBanner
        }
        elseif ($line -match $warnRegex) {
            $script:warnCount++
            Write-Host "[$stamp] $line" -ForegroundColor Yellow
        }
        elseif ($line -match '机器人已启动') {
            Write-Host "[$stamp] $line" -ForegroundColor Green
            Write-Box "[OK] 机器人已连接 Telegram 并开始监听 —— 现在可在 Telegram 里给机器人发 /start 测试" "Green"
        }
        else {
            Write-Host "[$stamp] $line"
        }
    }
    $exitCode = $LASTEXITCODE
}
finally {
    $elapsed = (Get-Date) - $startTime
    $sumColor = if ($script:errCount -gt 0) { "Red" } else { "Green" }
    Write-Host ""
    Write-Box ("测试结束 | 运行时长 {0:hh\:mm\:ss} | 异常 {1} | 警告 {2} | 退出码 {3}" -f $elapsed, $script:errCount, $script:warnCount, $exitCode) $sumColor
    Write-Host ("最近 {0} 行输出（异常行已标红）:" -f $ring.Count)
    foreach ($l in $ring) {
        if ($l -match $errRegex) { Write-Host ("  | " + $l) -ForegroundColor Red }
        else { Write-Host ("  | " + $l) }
    }
    Write-Host ("完整日志: " + $logFile)
    if (-not $NoPause) { try { [void](Read-Host "按回车关闭窗口") } catch {} }
}
