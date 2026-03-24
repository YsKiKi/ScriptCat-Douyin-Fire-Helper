<#
.SYNOPSIS
    抖音续火助手 - 调度脚本B (Windows)

.DESCRIPTION
    读取 config.json，按顺序启动不同 Profile 的浏览器实例，
    等待脚本A完成回调后关闭浏览器。

.PARAMETER Mode
    daemon - 守护进程模式，等待到配置的发送时间后执行（默认）
    once   - 立即执行一次

.EXAMPLE
    .\scheduler.ps1
    .\scheduler.ps1 -Mode once
#>

param(
    [ValidateSet("daemon", "once")]
    [string]$Mode = "daemon"
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogDir     = Join-Path $ScriptDir "logs"
$LogFile    = Join-Path $LogDir "scheduler_$(Get-Date -Format 'yyyyMMdd').log"

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# ==================== 日志 ====================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    switch ($Level) {
        "SUCCESS" { Write-Host $line -ForegroundColor Green  }
        "ERROR"   { Write-Host $line -ForegroundColor Red    }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        default   { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ==================== 配置 ====================
function Get-Config {
    if (-not (Test-Path $ConfigFile)) {
        Write-Log "配置文件不存在: $ConfigFile" "ERROR"
        exit 1
    }
    return Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ==================== 浏览器检测 ====================
function Find-Browser {
    param([string]$Browser, [object]$BrowserPaths)

    # 优先使用自定义路径
    $custom = $null
    try { $custom = $BrowserPaths.$Browser } catch {}
    if ($custom -and (Test-Path $custom)) { return $custom }

    $candidates = switch ($Browser) {
        "firefox" {
            @(
                "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
                "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
            )
        }
        "firefox-esr" {
            @(
                "$env:ProgramFiles\Mozilla Firefox ESR\firefox.exe",
                "${env:ProgramFiles(x86)}\Mozilla Firefox ESR\firefox.exe",
                "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
            )
        }
        "chrome" {
            @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
            )
        }
        "edge" {
            @(
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
            )
        }
        default { @() }
    }

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ==================== 启动浏览器 ====================
function Start-BrowserWithProfile {
    param([string]$Browser, [string]$BrowserPath, [string]$ProfilePath, [string]$Url)

    $browserArgs = switch -Wildcard ($Browser) {
        "firefox*" { @("--profile", $ProfilePath, "--no-remote", $Url) }
        default    { @("--user-data-dir=`"$ProfilePath`"", "--no-first-run", $Url) }
    }

    return Start-Process -FilePath $BrowserPath -ArgumentList $browserArgs -PassThru
}

# ==================== 等待到目标时间 ====================
function Wait-Until {
    param([string]$TimeStr)

    $parts  = $TimeStr -split ':'
    $target = (Get-Date).Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($parts.Count -ge 3) { $target = $target.AddSeconds([int]$parts[2]) }

    if ($target -le (Get-Date)) { $target = $target.AddDays(1) }

    $diff = $target - (Get-Date)
    Write-Log "距离下次发送 ($TimeStr) 还有 $([int]$diff.TotalHours)小时$($diff.Minutes)分钟"
    Start-Sleep -Seconds ([Math]::Max(1, [int]$diff.TotalSeconds))
}

# ==================== 查找 Python ====================
function Find-Python {
    foreach ($name in @("python3", "python")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# ==================== 处理单个账号 ====================
function Invoke-AccountTask {
    param(
        [string]$Name,
        [string]$ProfilePath,
        [string]$Browser,
        [int]$Port,
        [int]$Timeout,
        [string]$Url,
        [object]$BrowserPaths
    )

    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Log "处理账号: $Name"
    Write-Log "浏览器: $Browser | Profile: $ProfilePath"

    # 查找浏览器
    $browserPath = Find-Browser -Browser $Browser -BrowserPaths $BrowserPaths
    if (-not $browserPath) {
        Write-Log "未找到 $Browser 浏览器，请在 config.json 的 browser_paths 中指定路径" "ERROR"
        return $false
    }

    # 查找 Python
    $pythonExe = Find-Python
    if (-not $pythonExe) {
        Write-Log "未找到 Python 3，请安装 Python 3 并加入 PATH" "ERROR"
        return $false
    }

    # 启动回调服务器
    $serverScript  = Join-Path $ScriptDir "callback_server.py"
    $serverProcess = Start-Process -FilePath $pythonExe `
        -ArgumentList @($serverScript, $Port, $Timeout) `
        -PassThru -NoNewWindow -RedirectStandardError "NUL"
    Start-Sleep -Seconds 1

    if ($serverProcess.HasExited) {
        Write-Log "回调服务器启动失败（端口 $Port 可能被占用）" "ERROR"
        return $false
    }
    Write-Log "回调服务器已启动 (端口: $Port, PID: $($serverProcess.Id))"

    # 启动浏览器
    $browserProcess = Start-BrowserWithProfile -Browser $Browser `
        -BrowserPath $browserPath -ProfilePath $ProfilePath -Url $Url

    Write-Log "浏览器已启动 (PID: $($browserProcess.Id))"
    Write-Log "等待脚本A完成 (超时: ${Timeout}秒)..."

    # 等待回调服务器退出
    $serverProcess | Wait-Process -ErrorAction SilentlyContinue
    $exitCode = $serverProcess.ExitCode

    if ($exitCode -eq 0) {
        Write-Log "账号 $Name 任务完成" "SUCCESS"
    } else {
        Write-Log "账号 $Name 超时或失败 (退出码: $exitCode)" "ERROR"
    }

    # 关闭浏览器
    Write-Log "正在关闭浏览器..."
    try {
        Stop-Process -Id $browserProcess.Id -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (-not $browserProcess.HasExited) {
            Stop-Process -Id $browserProcess.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "浏览器可能已自行关闭" "WARN"
    }

    return ($exitCode -eq 0)
}

# ==================== 主流程 ====================
function Main {
    Write-Log "═══════════════════════════════════════"
    Write-Log " 抖音续火助手 - 调度脚本B (Windows)"
    Write-Log " 模式: $(if ($Mode -eq 'daemon') { '守护进程' } else { '单次执行' })"
    Write-Log "═══════════════════════════════════════"

    $config = Get-Config

    Write-Log "发送时间: $($config.send_time) | 端口: $($config.callback_port) | 超时: $($config.timeout_seconds)秒"
    Write-Log "默认浏览器: $($config.default_browser) | 账号数: $($config.accounts.Count)"

    while ($true) {
        if ($Mode -eq "daemon") {
            Wait-Until -TimeStr $config.send_time
        }

        Write-Log ""
        Write-Log "═══════════════════════════════════════"
        Write-Log " 开始执行 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "═══════════════════════════════════════"

        $success = 0
        $fail    = 0

        for ($i = 0; $i -lt $config.accounts.Count; $i++) {
            $acct    = $config.accounts[$i]
            $browser = if ($acct.browser) { $acct.browser } else { $config.default_browser }

            if (-not $acct.enabled) {
                Write-Log "跳过已禁用账号: $($acct.name)"
                continue
            }

            $result = Invoke-AccountTask `
                -Name         $acct.name `
                -ProfilePath  $acct.profile_path `
                -Browser      $browser `
                -Port         $config.callback_port `
                -Timeout      $config.timeout_seconds `
                -Url          $config.target_url `
                -BrowserPaths $config.browser_paths

            if ($result) { $success++ } else { $fail++ }

            if ($i -lt ($config.accounts.Count - 1)) {
                Write-Log "等待 5 秒后处理下一个账号..."
                Start-Sleep -Seconds 5
            }
        }

        Write-Log ""
        Write-Log "═══════════════════════════════════════"
        Write-Log " 任务完成: 成功=$success  失败=$fail"
        Write-Log "═══════════════════════════════════════"

        if ($Mode -ne "daemon") { break }

        # 防止同一分钟重复触发
        Start-Sleep -Seconds 61
    }
}

Main
