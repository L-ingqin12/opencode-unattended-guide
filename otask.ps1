# ==================================================================
# otask.ps1 — OpenCode 任务管理 (Windows PowerShell 版)
#
# 设计原则: 如无必要勿增实体。
# 核心: 把任务发给 opencode serve，等它跑完，拿结果。
#
# 用法:
#   .\otask.ps1 run    <task.md>  [-t host:port] [-d dir]
#   .\otask.ps1 send   "<prompt>" [-t host:port] [-d dir]
#   .\otask.ps1 status <sid>      [-t host:port]
#   .\otask.ps1 result <sid>      [-t host:port]
#   .\otask.ps1 continue <sid> "<prompt>" [-t host:port]
#   .\otask.ps1 sessions          [-t host:port]
#   .\otask.ps1 abort   <sid>     [-t host:port]
#   .\otask.ps1 setup   [-p pass] [-w C:\agent]
#   .\otask.ps1 secure  [-p pass] [-w C:\agent]
# ==================================================================

param(
    [string]$Command,
    [string[]]$Args
)

$ErrorActionPreference = "Stop"

# ── 默认配置 ──────────────────────────────────
$Target = if ($env:OTASK_TARGET) { $env:OTASK_TARGET } else { "127.0.0.1:4096" }
$Password = $env:OTASK_PASSWORD
$Timeout = if ($env:OTASK_TIMEOUT) { [int]$env:OTASK_TIMEOUT } else { 600 }
$PollSeconds = 2

# ── 解析参数 ──────────────────────────────────
$WorkDir = ""
$Agent = "build"
$Model = "anthropic/claude-sonnet-4"

$remainingArgs = [System.Collections.ArrayList]@()
for ($i = 0; $i -lt $Args.Count; $i++) {
    switch ($Args[$i]) {
        "-t" { $Target = $Args[++$i] }
        "--target" { $Target = $Args[++$i] }
        "-d" { $WorkDir = $Args[++$i] }
        "--dir" { $WorkDir = $Args[++$i] }
        "-a" { $Agent = $Args[++$i] }
        "--agent" { $Agent = $Args[++$i] }
        "-m" { $Model = $Args[++$i] }
        "--model" { $Model = $Args[++$i] }
        "-p" { $Password = $Args[++$i] }
        "--password" { $Password = $Args[++$i] }
        default { [void]$remainingArgs.Add($Args[$i]) }
    }
}

# ── HTTP 辅助 ──────────────────────────────────
function Http-Call($Method, $Path, $Body) {
    $uri = "http://$Target$Path"
    $headers = @{"Content-Type" = "application/json"}
    $securePassword = if ($Password) { ConvertTo-SecureString $Password -AsPlainText -Force } else { $null }

    $params = @{
        Uri = $uri
        Method = $Method
        Headers = $headers
        TimeoutSec = 30
    }
    if ($Body) { $params["Body"] = $Body }
    if ($securePassword) {
        $cred = New-Object System.Management.Automation.PSCredential("agent", $securePassword)
        $params["Credential"] = $cred
        $params["AllowUnencryptedAuthentication"] = $true
    }

    try {
        Invoke-RestMethod @params
    } catch {
        $_.Exception.Message | Write-Error
        return $null
    }
}

# ── 确保目标可达 ──────────────────────────────
function Ensure-Up {
    $health = Http-Call "GET" "/global/health"
    if (-not $health -or -not $health.healthy) {
        Write-Error "目标不可达: $Target"
        Write-Host "请确认目标机上 opencode serve 已启动" -ForegroundColor Yellow
        Write-Host "或在目标机上运行: .\otask.ps1 setup" -ForegroundColor Yellow
        exit 1
    }
}

# ── 等待任务完成 ──────────────────────────────
function Await-Task($Sid) {
    $start = Get-Date
    Write-Host "等待完成..." -NoNewline

    while ($true) {
        $elapsed = ((Get-Date) - $start).TotalSeconds
        $statusResp = Http-Call "GET" "/session/status"
        $status = if ($statusResp -and $statusResp.sessions -and $statusResp.sessions.$Sid) {
            $statusResp.sessions.$Sid.type
        } else { "unknown" }

        switch ($status) {
            "idle" {
                Write-Host ""
                Write-Host "完成 ($([math]::Round($elapsed))s)" -ForegroundColor Green
                return $true
            }
            "busy" {
                Write-Host "`r   busy $([math]::Round($elapsed))s / ${Timeout}s" -NoNewline
            }
            "retry" {
                Write-Host "`r   retry $([math]::Round($elapsed))s / ${Timeout}s" -NoNewline
            }
            default {
                Write-Host ""
                Write-Warning "未知状态: $status"
            }
        }

        if ($elapsed -gt $Timeout) {
            Write-Host ""
            Write-Error "超时 (${Timeout}s)，正在中断..."
            Http-Call "POST" "/session/$Sid/abort" | Out-Null
            return $false
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# ── 命令实现 ──────────────────────────────────

function Invoke-Run($TaskFile) {
    if (-not (Test-Path $TaskFile)) { Write-Error "文件不存在: $TaskFile"; exit 1 }
    Ensure-Up

    $content = Get-Content $TaskFile -Raw
    $title = ""
    $dirOverride = ""
    if ($content -match '(?s)^---\s*\ntitle:\s*(.+?)\s*\n') { $title = $Matches[1] }
    if ($content -match '(?s)^---\s*\n.*?directory:\s*(.+?)\s*\n') { $dirOverride = $Matches[1] }
    if ($dirOverride) { $WorkDir = $dirOverride }
    if (-not $WorkDir) { $WorkDir = "C:\opencode-agent" }

    # 去除 YAML frontmatter
    $body = $content -replace '(?s)^---.*?---\s*\n', ''

    Write-Host "任务: $title" -ForegroundColor Cyan
    Write-Host "目标: $Target  目录: $WorkDir"

    # 创建 session
    $sessionResp = Http-Call "POST" "/session" "{`"directory`":`"$WorkDir`"}"
    $sid = $sessionResp.id
    if (-not $sid) { Write-Error "创建 session 失败"; exit 1 }
    Write-Host "Session: $sid"

    # 发送 prompt
    $modelShort = $Model -replace '.*/', ''
    $bodyEscaped = $body -replace '"', '\"'
    $promptJson = @"
{"agent":"$Agent","model":{"providerID":"anthropic","modelID":"$modelShort"},"parts":[{"type":"text","text":"$bodyEscaped"}]}
"@
    Http-Call "POST" "/session/$sid/prompt" $promptJson | Out-Null

    if (Await-Task $sid) {
        $messages = Http-Call "GET" "/session/$sid/messages"
        $output = ($messages | ForEach-Object {
            $_.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }
        }) -join "`n`n"

        Write-Host ""
        Write-Host "═══════════════════════════════════════" -ForegroundColor Green
        Write-Host "  任务输出" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════" -ForegroundColor Green
        Write-Host $output
        Write-Host ""
        Write-Host "Session: $sid (已完成，可用 otask continue 继续)"
        Write-Output "OTASK_SESSION_ID=$sid"
    } else {
        Write-Output "OTASK_SESSION_ID=$sid"
        exit 2
    }
}

function Invoke-Send($Prompt) {
    Ensure-Up
    if (-not $WorkDir) { $WorkDir = "C:\opencode-agent" }

    Write-Host "发送: $($Prompt.Substring(0, [Math]::Min(80, $Prompt.Length)))..."

    $sessionResp = Http-Call "POST" "/session" "{`"directory`":`"$WorkDir`"}"
    $sid = $sessionResp.id
    if (-not $sid) { Write-Error "创建 session 失败"; exit 1 }

    $modelShort = $Model -replace '.*/', ''
    $promptEscaped = $Prompt -replace '"', '\"'
    $promptJson = @"
{"agent":"$Agent","model":{"providerID":"anthropic","modelID":"$modelShort"},"parts":[{"type":"text","text":"$promptEscaped"}]}
"@
    Http-Call "POST" "/session/$sid/prompt" $promptJson | Out-Null

    if (Await-Task $sid) { Invoke-Result $sid }
}

function Invoke-Status($Sid) {
    Ensure-Up
    $status = Http-Call "GET" "/session/status"
    if ($status -and $status.sessions -and $status.sessions.$Sid) {
        $status.sessions.$Sid | ConvertTo-Json -Depth 3
    } else {
        Write-Host "未找到 session: $Sid"
    }
}

function Invoke-Result($Sid) {
    Ensure-Up
    $messages = Http-Call "GET" "/session/$sid/messages"
    ($messages | ForEach-Object {
        $_.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }
    }) -join "`n`n"
}

function Invoke-Continue($Sid, $Prompt) {
    Ensure-Up
    Write-Host "继续: $Sid"

    $modelShort = $Model -replace '.*/', ''
    $promptEscaped = $Prompt -replace '"', '\"'
    $promptJson = @"
{"agent":"$Agent","model":{"providerID":"anthropic","modelID":"$modelShort"},"parts":[{"type":"text","text":"$promptEscaped"}]}
"@
    Http-Call "POST" "/session/$sid/prompt" $promptJson | Out-Null

    if (Await-Task $sid) { Invoke-Result $sid }
}

function Invoke-Sessions {
    Ensure-Up
    Write-Host "$Target 活跃 sessions:"
    $status = Http-Call "GET" "/session/status"
    if ($status -and $status.sessions) {
        $status.sessions | ConvertTo-Json -Depth 3
    }
}

function Invoke-Abort($Sid) {
    Ensure-Up
    Http-Call "POST" "/session/$sid/abort" | Out-Null
    Write-Host "已中断: $Sid"
}

function Invoke-Setup {
    param([bool]$Secure = $false)

    $pass = if ($Password) { $Password } else { "auto-" + [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(12)).Substring(0, 16) }
    if (-not $WorkDir) { $WorkDir = "C:\opencode-agent" }
    $port = if ($Target -match ':(\d+)$') { $Matches[1] } else { "4096" }

    $mode = if ($Secure) { "安全加固 (Agent白名单+目录沙箱)" } else { "标准" }
    Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  otask setup ($mode)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  端口: $port  目录: $WorkDir"

    # 安装 opencode
    try { opencode --version | Out-Null } catch { npm install -g opencode }

    # 目录
    New-Item -ItemType Directory -Force -Path "$WorkDir\reports", "$WorkDir\logs" | Out-Null

    # 权限配置
    if ($Secure) {
        $scriptDir = Split-Path $PSCommandPath -Parent
        $secureConfig = Join-Path $scriptDir "config\secure-opencode.json"
        if (Test-Path $secureConfig) {
            Copy-Item $secureConfig "$WorkDir\opencode.json"
            Write-Host "secure-opencode.json -> $WorkDir\opencode.json"
        } else {
            # 内联安全配置
            @'
{"default_agent":"analyzer","agent":{"analyzer":{"mode":"primary","permission":{"read":{"C:\\ProgramData\\**":"allow","C:\\opencode-agent\\**":"allow","*":"deny"},"edit":{"C:\\opencode-agent\\reports\\**":"allow","*":"deny"},"bash":{"findstr *":"allow","type *":"allow","Get-EventLog *":"allow","Get-Service *":"allow","Get-Process *":"allow","Get-Content *":"allow","*":"deny"},"task":"deny","webfetch":"deny","websearch":"deny","question":"deny","plan_enter":"deny","plan_exit":"deny"}}},"permission":{"*":"deny"}}
'@ | Set-Content "$WorkDir\opencode.json"
            Write-Host "内联安全配置"
        }
    } else {
        @'
{"permission":{"*":"allow","question":"allow","plan_enter":"allow","plan_exit":"allow"}}
'@ | Set-Content "$WorkDir\opencode.json"
    }

    # 环境变量
    [Environment]::SetEnvironmentVariable("OPENCODE_SERVER_PASSWORD", $pass, "Machine")
    [Environment]::SetEnvironmentVariable("OPENCODE_DISABLE_AUTOUPDATE", "true", "Machine")

    # 防火墙
    try {
        netsh advfirewall firewall delete rule name="OpenCode Agent" 2>$null
        netsh advfirewall firewall add rule name="OpenCode Agent" dir=in action=allow protocol=TCP localport=$port
        Write-Host "防火墙: TCP $port 已放行"
    } catch { Write-Warning "防火墙配置失败，请手动放行端口 $port" }

    # 设置环境变量
    $env:OPENCODE_SERVER_PASSWORD = $pass
    $env:OPENCODE_DISABLE_AUTOUPDATE = "true"

    # 提示后续操作
    Write-Host ""
    Write-Host "配置:" -ForegroundColor Green
    Write-Host "  `$env:OTASK_TARGET = '$(hostname):$port'"
    Write-Host "  `$env:OTASK_PASSWORD = '$pass'"
    Write-Host ""
    Write-Host "手动启动 serve:" -ForegroundColor Yellow
    Write-Host "  opencode serve --port $port --hostname 0.0.0.0"
    Write-Host ""
    Write-Host "或使用 NSSM 注册为 Windows 服务（自动重启）:" -ForegroundColor Yellow
    Write-Host "  nssm install OpenCodeAgent opencode serve --port $port --hostname 0.0.0.0"
    Write-Host "  nssm set OpenCodeAgent AppDirectory $WorkDir"
    Write-Host "  nssm set OpenCodeAgent Start SERVICE_AUTO_START"
    Write-Host "  nssm start OpenCodeAgent"
}

# ── 入口 ──────────────────────────────────────
switch ($Command) {
    "run"      { Invoke-Run $remainingArgs[0] }
    "send"     { Invoke-Send $remainingArgs[0] }
    "status"   { Invoke-Status $remainingArgs[0] }
    "result"   { Invoke-Result $remainingArgs[0] }
    "continue" { Invoke-Continue $remainingArgs[0] $remainingArgs[1] }
    "sessions" { Invoke-Sessions }
    "abort"    { Invoke-Abort $remainingArgs[0] }
    "setup"    { Invoke-Setup -Secure:$false }
    "secure"   { Invoke-Setup -Secure:$true }
    default {
        Write-Host "otask — OpenCode 任务管理 (Windows)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "用法:" -ForegroundColor Yellow
        Write-Host "  .\otask.ps1 run    <task.md>  [-t host:port] [-d dir]"
        Write-Host "  .\otask.ps1 send   '<prompt>' [-t host:port] [-d dir]"
        Write-Host "  .\otask.ps1 status <sid>      [-t host:port]"
        Write-Host "  .\otask.ps1 result <sid>      [-t host:port]"
        Write-Host "  .\otask.ps1 continue <sid> '<prompt>' [-t host:port]"
        Write-Host "  .\otask.ps1 sessions          [-t host:port]"
        Write-Host "  .\otask.ps1 abort   <sid>     [-t host:port]"
        Write-Host "  .\otask.ps1 setup   [-p pass] [-w C:\opencode-agent]"
        Write-Host "  .\otask.ps1 secure  [-p pass] [-w C:\opencode-agent]"
        Write-Host ""
        Write-Host "环境变量:" -ForegroundColor Yellow
        Write-Host "  `$env:OTASK_TARGET = host:port"
        Write-Host "  `$env:OTASK_PASSWORD = xxx"
        Write-Host "  `$env:OTASK_TIMEOUT = 600"
    }
}
