# ============================================================
# setup-agent.ps1 — OpenCode Agent Windows 部署机一键安装
#
# 在 Windows 部署机上以管理员身份运行:
#   powershell -ExecutionPolicy Bypass -File setup-agent.ps1
#
# 或指定参数:
#   .\setup-agent.ps1 -Password "mysecret" -Port 4096 -WorkDir "C:\opencode-agent"
# ============================================================

param(
    [string]$Password = "",
    [int]$Port = 4096,
    [string]$WorkDir = "C:\opencode-agent",
    [string]$AgentUser = ""
)

$ErrorActionPreference = "Stop"

# —— 生成密码 ——
if (-not $Password) {
    $Password = "auto-" + [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(12)).Substring(0, 16)
}

Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  OpenCode Agent Windows 部署机安装" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  工作目录: $WorkDir"
Write-Host "  端口:     $Port"
Write-Host ""

# —— 1. 检查 Node.js ——
$nodeVersion = $null
try { $nodeVersion = node --version 2>$null } catch {}
if (-not $nodeVersion) {
    Write-Host "❌ 需要 Node.js >= 20. 请先安装: https://nodejs.org" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Node.js: $nodeVersion"

# —— 2. 安装 OpenCode ——
$ocVersion = $null
try { $ocVersion = opencode --version 2>$null } catch {}
if (-not $ocVersion) {
    Write-Host "📦 安装 OpenCode..." -ForegroundColor Yellow
    npm install -g opencode
} else {
    Write-Host "✅ OpenCode 已安装: $ocVersion"
}

# —— 3. 创建工作目录 ——
New-Item -ItemType Directory -Force -Path "$WorkDir" | Out-Null
New-Item -ItemType Directory -Force -Path "$WorkDir\reports" | Out-Null
New-Item -ItemType Directory -Force -Path "$WorkDir\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "$WorkDir\tasks" | Out-Null
Write-Host "✅ 工作目录: $WorkDir"

# —— 4. 权限配置 ——
$configJson = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "permission": {
    "*": "allow",
    "question": "allow",
    "plan_enter": "allow",
    "plan_exit": "allow",
    "task": "allow",
    "bash": "allow",
    "edit": "allow",
    "read": "allow",
    "webfetch": "allow",
    "websearch": "allow"
  }
}
"@
Set-Content -Path "$WorkDir\opencode.json" -Value $configJson -Encoding UTF8
Write-Host "✅ 权限配置: allow all"

# —— 5. 环境变量 ——
[System.Environment]::SetEnvironmentVariable("OPENCODE_SERVER_PASSWORD", $Password, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("OPENCODE_DISABLE_AUTOUPDATE", "true", [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("OPENCODE_DISABLE_WATCHER", "true", [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("OPENCODE_WORKDIR", $WorkDir, [System.EnvironmentVariableTarget]::Machine)
Write-Host "✅ 环境变量已设置（机器级别）"

# —— 6. Windows 防火墙规则 ——
Write-Host "🔓 配置防火墙..."
try {
    # 删除旧规则（如果存在）
    netsh advfirewall firewall delete rule name="OpenCode Agent" 2>$null
    # 添加新规则
    netsh advfirewall firewall add rule `
        name="OpenCode Agent" `
        dir=in `
        action=allow `
        protocol=TCP `
        localport=$Port `
        description="OpenCode headless serve port"
    Write-Host "✅ 防火墙: TCP $Port 已放行"
} catch {
    Write-Host "⚠️  防火墙配置失败: $_" -ForegroundColor Yellow
    Write-Host "   请手动放行端口 $Port"
}

# —— 7. 注册 Windows 服务（通过 NSSM 或 WinSW） ——
# 优先使用 NSSM（如果已安装），否则使用简单的启动脚本 + Task Scheduler
$serviceName = "OpenCodeAgent"
$nssmPath = Get-Command nssm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source

if ($nssmPath) {
    Write-Host "🔧 使用 NSSM 注册 Windows 服务..."

    # 停止旧服务
    nssm stop $serviceName 2>$null
    nssm remove $serviceName confirm 2>$null

    $nodePath = (Get-Command node).Source
    $openCodePath = (Get-Command opencode).Source
    $appDir = Split-Path $openCodePath -Parent

    nssm install $serviceName $nodePath "`"$openCodePath`" serve --port $Port --hostname 0.0.0.0"
    nssm set $serviceName AppDirectory $WorkDir
    nssm set $serviceName AppEnvironmentExtra "OPENCODE_SERVER_PASSWORD=$Password OPENCODE_DISABLE_AUTOUPDATE=true OPENCODE_DISABLE_WATCHER=true"
    nssm set $serviceName DisplayName "OpenCode Agent Server"
    nssm set $serviceName Description "OpenCode headless AI coding agent server"
    nssm set $serviceName Start SERVICE_AUTO_START
    nssm set $serviceName AppStdout "$WorkDir\logs\stdout.log"
    nssm set $serviceName AppStderr "$WorkDir\logs\stderr.log"

    nssm start $serviceName
    Write-Host "✅ Windows 服务已注册并启动: $serviceName"
} else {
    Write-Host "⚠️  NSSM 未安装。使用 Task Scheduler 方案..." -ForegroundColor Yellow

    # 创建启动脚本
    $startScript = @"
@echo off
set OPENCODE_SERVER_PASSWORD=$Password
set OPENCODE_DISABLE_AUTOUPDATE=true
set OPENCODE_DISABLE_WATCHER=true
cd /d $WorkDir
opencode serve --port $Port --hostname 0.0.0.0 >> "$WorkDir\logs\serve.log" 2>&1
"@
    $startScriptPath = "$WorkDir\start-agent.bat"
    Set-Content -Path $startScriptPath -Value $startScript -Encoding ASCII

    # 创建计划任务（开机自启）
    $taskName = "OpenCode Agent Server"
    # 删除旧任务
    schtasks /delete /tn "$taskName" /f 2>$null

    schtasks /create `
        /tn "$taskName" `
        /tr "`"$startScriptPath`"" `
        /sc ONSTART `
        /ru SYSTEM `
        /rl HIGHEST `
        /f
    Write-Host "✅ 计划任务已创建: $taskName"

    # 立即启动
    schtasks /run /tn "$taskName"
    Write-Host "✅ 计划任务已启动"

    # 备用：提供手动后台运行的 PowerShell 命令
    $bgScriptPath = "$WorkDir\start-agent-background.ps1"
    @"
# 手动后台启动 OpenCode serve
`$env:OPENCODE_SERVER_PASSWORD = "$Password"
`$env:OPENCODE_DISABLE_AUTOUPDATE = "true"
`$env:OPENCODE_DISABLE_WATCHER = "true"
Set-Location "$WorkDir"
Start-Process -NoNewWindow -FilePath "opencode" -ArgumentList "serve", "--port", "$Port", "--hostname", "0.0.0.0"
Write-Host "OpenCode serve started on :$Port"
"@ | Set-Content -Path $bgScriptPath -Encoding UTF8
    Write-Host "   备用手动启动: powershell -File $bgScriptPath"
}

# —— 8. 自定义 agent ——
$agentDir = "$env:USERPROFILE\.config\opencode\agent"
if (-not (Test-Path $agentDir)) {
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
}
@"
---
name: analyzer
description: 日志和系统状态分析专家 — 可访问本机文件、日志和执行诊断命令
mode: primary
permission: allow
---
你是一台 Windows 部署机上的日志和系统状态分析专家。

你可以:
- 读取本机的任意日志文件和事件查看器
- 执行诊断命令 (Get-Service, Get-EventLog, Get-Process, type, findstr)
- 读取配置文件
- 分析错误模式并给出修复建议

操作原则:
1. 在不熟悉 PowerShell 命令时优先使用 opencode 内置工具（Read/Write/Edit）
2. 所有命令使用非交互标志
3. 不要进入 plan mode，直接执行
4. 不要询问问题，自行决策
5. 分析结果写入 $WorkDir\reports\ 目录
6. 注意 Windows 路径使用反斜杠或正斜杠均可
"@ | Set-Content -Path "$agentDir\analyzer.md" -Encoding UTF8
Write-Host "✅ 自定义 agent: analyzer (Windows 版)"

# —— 9. 输出摘要 ——
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq 'Dhcp' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress
if (-not $ip) { $ip = "localhost" }

Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✅ 安装完成" -ForegroundColor Green
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Serve URL:  http://${ip}:$Port" -ForegroundColor White
Write-Host "  Password:   $Password" -ForegroundColor White
Write-Host "  Workdir:    $WorkDir" -ForegroundColor White
Write-Host ""
Write-Host "  健康检查:" -ForegroundColor Gray
Write-Host "    curl http://localhost:$Port/global/health" -ForegroundColor Gray
Write-Host ""
Write-Host "  Controller 端配置 (machines.json):" -ForegroundColor Gray
Write-Host "    {" -ForegroundColor Gray
Write-Host "      `"windows-box`": {" -ForegroundColor Gray
Write-Host "        `"url`": `"http://${ip}:$Port`"," -ForegroundColor Gray
Write-Host "        `"password`": `"$Password`"," -ForegroundColor Gray
Write-Host "        `"labels`": [`"windows`", `"production`"]," -ForegroundColor Gray
Write-Host "        `"workdir`": `"$WorkDir`"" -ForegroundColor Gray
Write-Host "      }" -ForegroundColor Gray
Write-Host "    }" -ForegroundColor Gray
Write-Host ""
Write-Host "  管理命令:" -ForegroundColor Gray
Write-Host "    查看服务:  Get-Service OpenCodeAgent" -ForegroundColor Gray
Write-Host "    查看日志:  Get-Content $WorkDir\logs\serve.log -Tail 50" -ForegroundColor Gray
Write-Host "    API 文档:  http://localhost:$Port/docs" -ForegroundColor Gray
