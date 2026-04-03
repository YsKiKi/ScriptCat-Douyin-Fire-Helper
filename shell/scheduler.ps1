<#
.SYNOPSIS
    抖音续火助手 - 后端调度器 (Windows)

.DESCRIPTION
    读取 config.json，按顺序启动不同 Profile 的浏览器实例，
    等待浏览器执行脚本完成回调后关闭浏览器。

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

# ==================== 计算距离指定时间的秒数 ====================
function Get-SecondsUntil {
    param([string]$TimeStr)

    $parts  = $TimeStr -split ':'
    $target = (Get-Date).Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($parts.Count -ge 3) { $target = $target.AddSeconds([int]$parts[2]) }

    if ($target -le (Get-Date)) { $target = $target.AddDays(1) }

    return [int]($target - (Get-Date)).TotalSeconds
}

# ==================== 检查指定时间今天是否已过 ====================
function Test-TimePastToday {
    param([string]$TimeStr)

    $parts  = $TimeStr -split ':'
    $target = (Get-Date).Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($parts.Count -ge 3) { $target = $target.AddSeconds([int]$parts[2]) }

    return (Get-Date) -ge $target
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
# 返回 hashtable: { Success=$bool; TimedOut=$bool; BrowserPid=$int }
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
        return @{ Success = $false; TimedOut = $false; BrowserPid = 0 }
    }

    # 查找 Python
    $pythonExe = Find-Python
    if (-not $pythonExe) {
        Write-Log "未找到 Python 3，请安装 Python 3 并加入 PATH" "ERROR"
        return @{ Success = $false; TimedOut = $false; BrowserPid = 0 }
    }

    # 启动回调服务器
    $serverScript  = Join-Path $ScriptDir "callback_server.py"
    $serverProcess = Start-Process -FilePath $pythonExe `
        -ArgumentList @($serverScript, $Port, $Timeout) `
        -PassThru -NoNewWindow -RedirectStandardError "NUL"
    Start-Sleep -Seconds 1

    if ($serverProcess.HasExited) {
        Write-Log "回调服务器启动失败（端口 $Port 可能被占用）" "ERROR"
        return @{ Success = $false; TimedOut = $false; BrowserPid = 0 }
    }
    Write-Log "回调服务器已启动 (端口: $Port, PID: $($serverProcess.Id))"

    # 启动浏览器
    $browserProcess = Start-BrowserWithProfile -Browser $Browser `
        -BrowserPath $browserPath -ProfilePath $ProfilePath -Url $Url

    Write-Log "浏览器已启动 (PID: $($browserProcess.Id))"
    Write-Log "等待浏览器执行脚本完成 (超时: ${Timeout}秒)..."

    # 等待回调服务器退出
    $serverProcess | Wait-Process -ErrorAction SilentlyContinue
    $exitCode = $serverProcess.ExitCode

    if ($exitCode -eq 0) {
        Write-Log "账号 $Name 任务完成，关闭浏览器" "SUCCESS"
        try {
            Stop-Process -Id $browserProcess.Id -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if (-not $browserProcess.HasExited) {
                Stop-Process -Id $browserProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log "浏览器可能已自行关闭" "WARN"
        }
        return @{ Success = $true; TimedOut = $false; BrowserPid = 0 }
    } else {
        Write-Log "账号 $Name 回调超时，保留浏览器继续等待" "WARN"
        return @{ Success = $false; TimedOut = $true; BrowserPid = $browserProcess.Id }
    }
}

# ==================== 仅等待回调（浏览器已在运行）====================
# 返回 hashtable: { Success=$bool; TimedOut=$bool }
function Invoke-WaitForCallback {
    param(
        [string]$Name,
        [int]$Port,
        [int]$Timeout
    )

    $pythonExe = Find-Python
    if (-not $pythonExe) {
        Write-Log "未找到 Python 3" "ERROR"
        return @{ Success = $false; TimedOut = $false }
    }

    $serverScript  = Join-Path $ScriptDir "callback_server.py"
    $serverProcess = Start-Process -FilePath $pythonExe `
        -ArgumentList @($serverScript, $Port, $Timeout) `
        -PassThru -NoNewWindow -RedirectStandardError "NUL"
    Start-Sleep -Seconds 1

    if ($serverProcess.HasExited) {
        Write-Log "回调服务器启动失败（端口 $Port 可能被占用）" "ERROR"
        return @{ Success = $false; TimedOut = $false }
    }
    Write-Log "回调服务器已重启，等待账号 $Name 重新通知 (超时: ${Timeout}秒)..."

    $serverProcess | Wait-Process -ErrorAction SilentlyContinue
    $exitCode = $serverProcess.ExitCode

    if ($exitCode -eq 0) {
        return @{ Success = $true; TimedOut = $false }
    } else {
        Write-Log "账号 $Name 再次超时" "WARN"
        return @{ Success = $false; TimedOut = $true }
    }
}

# ==================== 主流程 ====================
function Main {
    Write-Log "═══════════════════════════════════════"
    Write-Log " 抖音续火助手 - 后端调度器 (Windows)"
    Write-Log " 模式: $(if ($Mode -eq 'daemon') { '守护进程' } else { '单次执行' })"
    Write-Log "═══════════════════════════════════════"

    $config = Get-Config

    $defaultSendTime = $config.send_time
    Write-Log "全局发送时间: $defaultSendTime | 端口: $($config.callback_port) | 超时: $($config.timeout_seconds)秒"
    Write-Log "默认浏览器: $($config.default_browser) | 账号数: $($config.accounts.Count)"

    # 打印每个账号的发送时间
    for ($i = 0; $i -lt $config.accounts.Count; $i++) {
        $acct = $config.accounts[$i]
        if (-not $acct.enabled) { continue }
        $acctTime = if ($acct.send_time) { $acct.send_time } else { $defaultSendTime }
        Write-Log "  $($acct.name): 发送时间 $acctTime"
    }

    if ($Mode -ne "daemon") {
        # ---- once 模式：立即执行所有已启用账号 ----
        Write-Log ""
        Write-Log "═══════════════════════════════════════"
        Write-Log " 开始执行 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "═══════════════════════════════════════"

        $success     = 0
        $fail        = 0
        $timedOutAt  = @{}
        $timedOutPids= @{}

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

            if ($result.Success) { $success++ } else { $fail++ }

            # 超时时浏览器仍在运行，记录以便后续重试
            if ($result.TimedOut) {
                $timedOutPids[$i] = $result.BrowserPid
                $timedOutAt[$i]   = Get-Date
            }

            if ($i -lt ($config.accounts.Count - 1)) {
                Write-Log "等待 5 秒后处理下一个账号..."
                Start-Sleep -Seconds 5
            }
        }

        # 等待所有超时账号重试完成
        $retryWaitMinutes = if ($config.retry_wait_minutes) { [int]$config.retry_wait_minutes } else { 25 }
        if ($timedOutAt.Count -gt 0) {
            Write-Log "有 $($timedOutAt.Count) 个账号超时，等待 ${retryWaitMinutes} 分钟后重试..."
            Start-Sleep -Seconds ($retryWaitMinutes * 60)
            foreach ($idx in @($timedOutAt.Keys)) {
                $acct = $config.accounts[$idx]
                Write-Log "重试账号: $($acct.name)"
                $retryResult = Invoke-WaitForCallback `
                    -Name    $acct.name `
                    -Port    $config.callback_port `
                    -Timeout $config.timeout_seconds
                if ($retryResult.Success) {
                    Write-Log "账号 $($acct.name) 重试成功" "SUCCESS"
                    $success++; $fail--
                } else {
                    Write-Log "账号 $($acct.name) 重试仍超时或失败" "ERROR"
                }
                # 无论结果，关闭对应浏览器
                $pid = $timedOutPids[$idx]
                try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
            }
        }

        Write-Log ""
        Write-Log "═══════════════════════════════════════"
        Write-Log " 任务完成: 成功=$success  失败=$fail"
        Write-Log "═══════════════════════════════════════"
    }
    else {
        # ---- daemon 模式：按每个账号的 send_time 分别调度 ----
        $executedToday  = @{}   # 已完成（成功或放弃）的账号索引
        $timedOutAt     = @{}   # 超时的账号索引 -> 超时时间
        $timedOutPids   = @{}   # 超时的账号索引 -> 浏览器 PID
        $retryWaitMinutes = if ($config.retry_wait_minutes) { [int]$config.retry_wait_minutes } else { 25 }
        $currentDay = (Get-Date).ToString("yyyyMMdd")

        while ($true) {
            # 日期变更时重置
            $today = (Get-Date).ToString("yyyyMMdd")
            if ($today -ne $currentDay) {
                Write-Log "新的一天，重置执行记录"
                # 杀掉所有仍在等待的超时浏览器
                foreach ($pid in $timedOutPids.Values) {
                    try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
                }
                $executedToday  = @{}
                $timedOutAt     = @{}
                $timedOutPids   = @{}
                $currentDay = $today
            }

            # ---- 检查超时账号是否已到重试时间 ----
            foreach ($idx in @($timedOutAt.Keys)) {
                $elapsedMin = ((Get-Date) - $timedOutAt[$idx]).TotalMinutes
                if ($elapsedMin -lt $retryWaitMinutes) { continue }

                $acct = $config.accounts[$idx]
                Write-Log ""
                Write-Log "═══════════════════════════════════════"
                Write-Log " 重试超时账号: $($acct.name) @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                Write-Log "═══════════════════════════════════════"

                $retryResult = Invoke-WaitForCallback `
                    -Name    $acct.name `
                    -Port    $config.callback_port `
                    -Timeout $config.timeout_seconds

                if ($retryResult.Success) {
                    Write-Log "账号 $($acct.name) 重试成功，关闭浏览器" "SUCCESS"
                    try { Stop-Process -Id $timedOutPids[$idx] -Force -ErrorAction SilentlyContinue } catch {}
                    $executedToday[$idx] = $true
                    $timedOutAt.Remove($idx)
                    $timedOutPids.Remove($idx)
                } elseif ($retryResult.TimedOut) {
                    Write-Log "账号 $($acct.name) 重试仍超时，继续等待 ${retryWaitMinutes} 分钟" "WARN"
                    $timedOutAt[$idx] = Get-Date   # 重置计时
                } else {
                    Write-Log "账号 $($acct.name) 重试失败，关闭浏览器" "ERROR"
                    try { Stop-Process -Id $timedOutPids[$idx] -Force -ErrorAction SilentlyContinue } catch {}
                    $executedToday[$idx] = $true
                    $timedOutAt.Remove($idx)
                    $timedOutPids.Remove($idx)
                }
            }

            # ---- 找到下一个需要执行的账号（跳过已完成和超时等待中的） ----
            $nextIndex   = -1
            $nextSeconds = 999999
            $nextTimeStr = ""

            for ($i = 0; $i -lt $config.accounts.Count; $i++) {
                $acct = $config.accounts[$i]
                if (-not $acct.enabled) { continue }
                if ($executedToday.ContainsKey($i)) { continue }
                if ($timedOutAt.ContainsKey($i)) { continue }   # 超时等待中，跳过

                $acctTime = if ($acct.send_time) { $acct.send_time } else { $defaultSendTime }

                # 时间已过且未执行 → 立即执行
                if (Test-TimePastToday -TimeStr $acctTime) {
                    $nextIndex   = $i
                    $nextSeconds = 0
                    $nextTimeStr = $acctTime
                    break
                }

                $secs = Get-SecondsUntil -TimeStr $acctTime
                if ($secs -lt $nextSeconds) {
                    $nextSeconds = $secs
                    $nextIndex   = $i
                    $nextTimeStr = $acctTime
                }
            }

            if ($nextIndex -eq -1) {
                if ($timedOutAt.Count -gt 0) {
                    # 仍有超时账号在等待，短暂休眠后继续轮询
                    Start-Sleep -Seconds 60
                    continue
                }
                Write-Log "今日所有账号已执行完毕，等待至明天..."
                $tomorrow = (Get-Date).Date.AddDays(1).AddSeconds(1)
                $sleepSecs = [int]($tomorrow - (Get-Date)).TotalSeconds
                Start-Sleep -Seconds ([Math]::Max(1, $sleepSecs))
                continue
            }

            $acct    = $config.accounts[$nextIndex]
            $browser = if ($acct.browser) { $acct.browser } else { $config.default_browser }

            if ($nextSeconds -gt 0) {
                Write-Log "下一个账号: $($acct.name) ($nextTimeStr)"
                Wait-Until -TimeStr $nextTimeStr
            }

            Write-Log ""
            Write-Log "═══════════════════════════════════════"
            Write-Log " 执行账号: $($acct.name) @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Write-Log "═══════════════════════════════════════"

            $result = Invoke-AccountTask `
                -Name         $acct.name `
                -ProfilePath  $acct.profile_path `
                -Browser      $browser `
                -Port         $config.callback_port `
                -Timeout      $config.timeout_seconds `
                -Url          $config.target_url `
                -BrowserPaths $config.browser_paths

            if ($result.Success) {
                Write-Log "账号 $($acct.name) 完成" "SUCCESS"
                $executedToday[$nextIndex] = $true
            } elseif ($result.TimedOut) {
                Write-Log "账号 $($acct.name) 超时，保留浏览器，${retryWaitMinutes} 分钟后重试" "WARN"
                $timedOutAt[$nextIndex]   = Get-Date
                $timedOutPids[$nextIndex] = $result.BrowserPid
                # 不标记 executedToday，由重试逻辑处理
            } else {
                Write-Log "账号 $($acct.name) 失败（非超时）" "ERROR"
                $executedToday[$nextIndex] = $true
            }

            Start-Sleep -Seconds 5
        }
    }
}

Main
