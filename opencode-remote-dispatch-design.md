# OpenCode 远程任务分发与心跳监控 — 完整架构设计

> 解决三大核心问题：
> 1. `--format json` 正确提取 session_id（非 `--json`）
> 2. 心跳检测 `opencode run` 任务状态，获取最终报告
> 3. 远程部署机任务分发：上传 agent 定义，在目标机本地路径/工具/日志上下文中执行分析

---

## 目录

- [1. 架构总览](#1-架构总览)
- [2. Session ID 正确提取方案](#2-session-id-正确提取方案)
- [3. 心跳监控方案](#3-心跳监控方案)
- [4. 远程任务分发方案](#4-远程任务分发方案)
- [5. 完整部署指南](#5-完整部署指南)
- [6. Windows + Linux 双平台适配](#6-windows--linux-双平台适配)
- [7. 故障处理](#7-故障处理)

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                     Controller (调度机)                          │
│                                                                   │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────────────────┐ │
│  │ 任务队列  │   │ heartbeat.sh │   │ dispatch.sh              │ │
│  │ tasks/    │──▶│ - 解析NDJSON │──▶│ - 分发到远程 serve       │ │
│  │ *.md      │   │ - 心跳检测   │   │ - 收集结果到 reports/    │ │
│  └──────────┘   │ - 超时告警   │   └──────────────────────────┘ │
│                  └──────────────┘                                 │
└──────────────────────┬──────────────────────────────────────────┘
                       │ HTTP / SSH Tunnel / Tailscale
       ┌───────────────┼───────────────────────────┐
       ▼               ▼                           ▼
┌──────────────┐ ┌──────────────┐         ┌──────────────┐
│ 部署机 A      │ │ 部署机 B      │   ...   │ 部署机 N      │
│              │ │              │         │              │
│ opencode     │ │ opencode     │         │ opencode     │
│ serve :4096  │ │ serve :4096  │         │ serve :4096  │
│              │ │              │         │              │
│ 本地资源:     │ │ 本地资源:     │         │ 本地资源:     │
│ /var/log/app │ │ /opt/svc/log │         │ /home/deploy │
│ /etc/config  │ │ agent-b.md   │         │ /data/db     │
│ agent-a.md   │ │ tools/       │         │ tools/       │
└──────────────┘ └──────────────┘         └──────────────┘
```

### 三种执行模式对比

| 模式 | 命令 | 适用场景 | Session ID 获取 |
|------|------|----------|-----------------|
| **本地 CLI** | `opencode run --format json` | 单机自动化、CI | NDJSON 首行解析 |
| **本地 Serve** | `opencode serve` + REST API | 同机多任务调度 | API 返回 `{ id }` |
| **远程 Serve** | `opencode serve` + HTTP 调用 | 跨机分发 | API 返回 `{ id }` |
| **Web 模式** | `opencode web` | 人工远程监控/控制 | 浏览器 UI 可见 |

---

## 2. Session ID 正确提取方案

### 2.1 问题

`--json` 参数行为不稳定，无法可靠获取 session_id。正确方式是使用 `--format json` 产生 NDJSON 流。

### 2.2 方案 A：NDJSON 流解析（推荐）

```bash
opencode run --format json "你的任务" 2>/tmp/oc-stderr.log | tee /tmp/oc-events.ndjson

# 提取 session_id（第一行事件就包含）
SESSION_ID=$(head -1 /tmp/oc-events.ndjson | jq -r '.sessionID')
echo "Session: $SESSION_ID"
```

NDJSON 每行事件结构：

```json
{"type":"step_start","timestamp":1718000000000,"sessionID":"ses_abc123","step":1}
{"type":"text","timestamp":1718000001000,"sessionID":"ses_abc123","content":"正在分析..."}
{"type":"tool_use","timestamp":1718000002000,"sessionID":"ses_abc123","tool":"bash","input":{...}}
{"type":"tool_result","timestamp":1718000005000,"sessionID":"ses_abc123","output":"..."}
{"type":"step_finish","timestamp":1718000010000,"sessionID":"ses_abc123","step":1}
```

### 2.3 方案 B：`--on-complete` 钩子

```bash
opencode run --format json "任务" \
  --on-complete 'echo "SESSION_ID=$SESSION_ID EXIT=$EXIT_CODE DURATION=$DURATION_MS" >> /tmp/oc-result.env'
```

钩子环境变量：

| 变量 | 含义 |
|------|------|
| `SESSION_ID` | 本次会话 ID |
| `EXIT_CODE` | 退出码（0=成功） |
| `DURATION_MS` | 执行耗时（毫秒） |
| `MESSAGE_COUNT` | 消息轮次总数 |

### 2.4 方案 C：Serve API 直接返回

```bash
# 创建 session 直接拿到 id
curl -s -X POST http://localhost:4096/session \
  -H 'Content-Type: application/json' \
  -d '{"directory":"/path/to/project"}' \
  | jq -r '.id'
# 输出: sess_2dac160bb71f
```

---

## 3. 心跳监控方案

### 3.1 监控维度

| 维度 | 信号 | 阈值 | 动作 |
|------|------|------|------|
| **活跃度** | NDJSON 有新事件产出 | 300s 无事件 | 告警 → 中断 → 重试 |
| **进度** | `step_start` / `step_finish` 配对 | — | 进度百分比估算 |
| **工具调用** | `tool_use` / `tool_result` 配对 | 单工具 600s 超时 | 告警 |
| **完成** | 流关闭 + `step_finish` 最终事件 | — | 提取报告 |
| **错误** | `"type":"error"` 事件 | — | 记录 → 重试或跳过 |

### 3.2 实现：NDJSON 流心跳

```
heartbeat.sh 原理:
  ┌──────────────────────────────────────────────────┐
  │  tail -f /tmp/oc-events.ndjson                    │
  │       │                                           │
  │       ▼                                           │
  │  ┌─────────┐   ┌──────────┐   ┌───────────────┐  │
  │  │ 解析事件 │──▶│ 更新状态  │──▶│ 检查超时条件  │  │
  │  └─────────┘   └──────────┘   └───────┬───────┘  │
  │                                       │           │
  │                     ┌─────────────────┘           │
  │                     ▼                             │
  │  ┌─────────────────────────────────────────────┐  │
  │  │ 超时？→ 向 opencode 进程发 SIGTERM            │  │
  │  │ 完成？→ 收集最终 text 事件 → 生成报告          │  │
  │  │ 错误？→ 记录 error 事件                       │  │
  │  └─────────────────────────────────────────────┘  │
  └──────────────────────────────────────────────────┘
```

### 3.3 实现：Serve API 心跳

```bash
# 轮询 session 状态（每 2 秒）
while true; do
    STATUS=$(curl -s http://HOST:4096/session/status \
        | jq -r ".sessions.\"$SESSION_ID\".type // \"unknown\"")

    case "$STATUS" in
        idle)   echo "✅ 完成"; break ;;
        busy)   echo "⏳ 执行中..."; sleep 2 ;;
        retry)  echo "🔄 重试中..."; sleep 2 ;;
        *)      echo "⚠️ 未知状态: $STATUS"; sleep 5 ;;
    esac
done

# 获取最终消息（报告）
curl -s http://HOST:4096/session/$SESSION_ID/messages | jq '.'
```

### 3.4 实现：SSE 事件流（最实时）

```bash
curl -N -s http://HOST:4096/session/$SESSION_ID/event 2>&1 | while IFS= read -r line; do
    # 过滤 SSE data 行
    if [[ "$line" =~ ^data:\ (.*) ]]; then
        event="${BASH_REMATCH[1]}"
        type=$(echo "$event" | jq -r '.type // empty')

        case "$type" in
            "part.updated")     echo "📝 $(echo "$event" | jq -r '.part.text // ""' | tail -c 200)" ;;
            "tool.call")        echo "🔧 $(echo "$event" | jq -r '.tool.name')" ;;
            "session.updated")  echo "📌 状态更新" ;;
            "permission.replied") echo "🔓 权限已响应" ;;
        esac

        # 检测完成
        stop_reason=$(echo "$event" | jq -r '.session.stopReason // empty')
        if [ -n "$stop_reason" ]; then
            echo "🏁 结束: $stop_reason"
            break
        fi
    fi
done
```

---

## 4. 远程任务分发方案

### 4.1 核心问题

部署机上有：
- **本地工具**：部署机特有的二进制、脚本、MCP server
- **本地 agent**：`~/.config/opencode/agent/` 下自定义 agent 定义
- **本地路径**：日志目录 `/var/log/app`、配置 `/etc/myapp`、数据 `/data/db`
- **本地环境**：环境变量、SSH key、k8s context

需要从远程上传**任务定义**并在**部署机本地上下文**中执行。

### 4.2 分发流程

```
┌─────────── 任务准备（Controller）───────────┐
│                                               │
│  1. 编写任务文件: task-001.md                  │
│     ---                                       │
│     title: 分析 /var/log/app/error.log        │
│     agent: analyzer                           │
│     machine: deploy-prod-01                   │
│     ---                                       │
│     请使用本地 agent "analyzer" 分析           │
│     /var/log/app/error.log 中的错误...         │
│                                               │
│  2. 附加上下文文件（可选）                      │
│     task-001-context.md                       │
│                                               │
│  3. 推送任务到目标机                            │
│     dispatch.sh push deploy-prod-01 task-001   │
│                                               │
└───────────────────┬───────────────────────────┘
                    │
                    ▼
┌─────────── 任务执行（部署机）─────────────────┐
│                                               │
│  4. opencode serve 收到 POST /session          │
│     参数: directory=/opt/app (部署机路径)       │
│     prompt: 任务文件内容                        │
│                                               │
│  5. Agent 在部署机本地执行:                     │
│     - 读取 /var/log/app/error.log (本地文件)    │
│     - 调用本地 MCP tools                        │
│     - 使用本地 agent 定义                       │
│     - 执行本地 shell 命令                       │
│                                               │
│  6. 返回结果                                    │
│     - 消息流通过 SSE 实时回传                    │
│     - 最终报告写入 reports/task-001-report.md   │
│                                               │
└───────────────────┬───────────────────────────┘
                    │
                    ▼
┌─────────── 结果收集（Controller）─────────────┐
│                                               │
│  7. Heartbeat 检测到 idle → 拉取结果            │
│  8. 报告聚合到 reports/ 目录                    │
│  9. 通知用户（webhook / PushNotification）      │
│                                               │
└───────────────────────────────────────────────┘
```

### 4.3 部署机配置

每台部署机需要：

```bash
# 1. 安装 opencode
npm install -g opencode

# 2. 配置无人值守权限
cat > /opt/opencode-agent/opencode.json << 'EOF'
{
  "permission": {"*": "allow", "question": "allow", "plan_enter": "allow", "plan_exit": "allow"}
}
EOF

# 3. 安装自定义 agent
mkdir -p ~/.config/opencode/agent/
cat > ~/.config/opencode/agent/analyzer.md << 'EOF'
---
name: analyzer
description: 日志和系统状态分析专家
mode: primary
permission: allow
---
你是一个部署机日志分析专家。你可以访问本机的日志文件、系统状态和配置。
EOF

# 4. 设置认证密码
export OPENCODE_SERVER_PASSWORD="deploy-machine-secret"

# 5. 启动 serve（systemd 托管）
systemctl start opencode-agent
```

### 4.4 进程托管方案（按平台）

#### Linux: systemd

```ini
# /etc/systemd/system/opencode-agent.service
[Unit]
Description=OpenCode Agent Server
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/opt/opencode-agent
Environment="OPENCODE_SERVER_PASSWORD=deploy-machine-secret"
Environment="OPENCODE_DISABLE_AUTOUPDATE=true"
Environment="OPENCODE_DISABLE_WATCHER=true"
ExecStart=/usr/bin/opencode serve --port 4096 --hostname 0.0.0.0
Restart=always
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

#### Windows: NSSM (推荐) 或 Task Scheduler

```powershell
# NSSM 方式（推荐，重启自动恢复）
nssm install OpenCodeAgent "C:\Program Files\nodejs\node.exe" `
    "C:\Users\deploy\AppData\Roaming\npm\opencode.cmd serve --port 4096 --hostname 0.0.0.0"
nssm set OpenCodeAgent AppDirectory C:\opencode-agent
nssm set OpenCodeAgent AppEnvironmentExtra "OPENCODE_SERVER_PASSWORD=secret OPENCODE_DISABLE_AUTOUPDATE=true"
nssm set OpenCodeAgent Start SERVICE_AUTO_START
nssm start OpenCodeAgent

# Task Scheduler 方式（无需额外工具）
schtasks /create /tn "OpenCode Agent" `
    /tr "C:\opencode-agent\start-agent.bat" `
    /sc ONSTART /ru SYSTEM /rl HIGHEST /f
schtasks /run /tn "OpenCode Agent"
```

### 4.5 Windows vs Linux 路径映射

任务文件中的路径使用**占位符**机制，由 dispatch.sh 根据目标 OS 自动转换：

| 占位符 | Linux 展开 | Windows 展开 |
|--------|-----------|-------------|
| `{LOGDIR}` | `/var/log/app` | `C:\ProgramData\app\logs` |
| `{CONFDIR}` | `/etc/myapp` | `C:\ProgramData\app\config` |
| `{WORKDIR}` | `/opt/opencode-agent` | `C:\opencode-agent` |
| `{REPORTS}` | `{WORKDIR}/reports` | `{WORKDIR}\reports` |

dispatch.sh 在发送任务前执行路径替换：

```bash
# dispatch.sh 内部
if [[ "$MACHINE_OS" == "windows" ]]; then
    prompt_text="${prompt_text//\{LOGDIR\}/C:\\ProgramData\\app\\logs}"
    prompt_text="${prompt_text//\{CONFDIR\}/C:\\ProgramData\\app\\config}"
else
    prompt_text="${prompt_text//\{LOGDIR\}/\/var\/log\/app}"
    prompt_text="${prompt_text//\{CONFDIR\}/\/etc\/myapp}"
fi
```
Environment="HOME=/home/deploy"
ExecStart=/usr/bin/opencode serve --port 4096 --hostname 0.0.0.0
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### 4.5 任务文件格式

每个任务是一个 Markdown 文件，YAML frontmatter 描述元数据：

```markdown
---
# 任务元数据
title: 分析生产环境错误日志
agent: analyzer
model: anthropic/claude-sonnet-4
machine: deploy-prod-01          # 目标部署机
directory: /opt/myapp             # 部署机上的工作目录
timeout: 600                      # 超时秒数
notify: webhook                   # 完成通知方式
tags: [production, error-analysis]
context_files:                    # 附加上下文（从 Controller 上传）
  - app-config.yaml
  - known-issues.md
---

# 任务: 分析 /var/log/app/error.log

## 执行步骤

1. 读取 /var/log/app/error.log 最近 1 小时的内容
2. 使用本地 agent "analyzer" 分类错误类型
3. 关联 /etc/myapp/config.yaml 中的配置检查是否有配置错误
4. 输出分析报告，包含：
   - 错误分类统计
   - TOP 5 高频错误及根因
   - 修复建议

## 输出

将报告写入 /opt/opencode-agent/reports/task-$(date +%Y%m%d-%H%M%S).md
同时通过 webhook 发送摘要。
```

### 4.6 安全通道

```
Controller ──── HTTPS/TLS ────▶ Deploy Machine (opencode serve)
                                 │
                                 ├── Basic Auth (OPENCODE_SERVER_PASSWORD)
                                 └── 或 Tailscale private network (推荐)
```

**推荐方案（Tailscale）**：
```
Controller (100.64.0.1) ── Tailscale mesh ──▶ Deploy-A (100.64.0.2)
                                              Deploy-B (100.64.0.3)
# 无需暴露公网端口
curl -u "agent:$PASSWORD" http://100.64.0.2:4096/session
```

---

## 5. 完整部署指南

### 5.1 Controller 端

```bash
# 目录结构
mkdir -p ~/opencode-controller/{tasks,reports,scripts,logs}

# 克隆本指南
git clone https://github.com/L-ingqin12/opencode-unattended-guide.git
cd opencode-unattended-guide

# 配置部署机列表
cat > ~/opencode-controller/machines.json << 'EOF'
{
  "deploy-prod-01": {
    "url": "http://100.64.0.2:4096",
    "password": "deploy-machine-secret",
    "labels": ["production", "app-server"],
    "os": "linux"
  },
  "windows-build-01": {
    "url": "http://192.168.1.50:4096",
    "password": "deploy-machine-secret",
    "labels": ["production", "build-server"],
    "os": "windows"
  },
  "deploy-prod-02": {
    "url": "http://100.64.0.3:4096",
    "password": "deploy-machine-secret",
    "labels": ["production", "db-server"]
  }
}
EOF
```

### 5.2 部署机端

```bash
# 在每台部署机执行
curl -sL https://raw.githubusercontent.com/L-ingqin12/opencode-unattended-guide/main/scripts/setup-agent.sh | bash
```

### 5.3 分发任务

```bash
# 单任务分发
./scripts/dispatch.sh push deploy-prod-01 tasks/analyze-errors.md

# 批量分发（所有 production 机器）
./scripts/dispatch.sh push-all production tasks/health-check.md

# 查看任务状态
./scripts/dispatch.sh status deploy-prod-01

# 拉取报告
./scripts/dispatch.sh report deploy-prod-01 sess_xxx
```

---

## 6. Windows + Linux 双平台适配

### 6.1 架构对比

| 维度 | Linux | Windows |
|------|-------|---------|
| 进程托管 | systemd service | NSSM / Task Scheduler |
| 安装脚本 | `setup-agent.sh` | `setup-agent.ps1` |
| 默认工作目录 | `/opt/opencode-agent` | `C:\opencode-agent` |
| 配置文件位置 | `$WORKDIR/opencode.json` | `$WORKDIR\opencode.json` |
| Agent 目录 | `~/.config/opencode/agent/` | `%USERPROFILE%\.config\opencode\agent\` |
| 日志路径示例 | `/var/log/app/` | `C:\ProgramData\app\logs\` |
| 路径分隔符 | `/` | `\` 或 `/`（均可） |
| 环境变量设置 | `export` / systemd Environment= | `[Environment]::SetEnvironmentVariable` |
| 防火墙 | iptables / nftables / ufw | netsh advfirewall |
| 包管理器 | npm (global install) | npm (global install) |
| Shell | bash / sh | PowerShell / cmd |
| SSH 可用性 | 通常内置 | 需额外配置或使用 HTTP+Auth |

### 6.2 一键安装

| 平台 | 命令 |
|------|------|
| Linux | `curl -sL <raw-url>/scripts/setup-agent.sh \| bash` |
| Windows | `powershell -Exec Bypass -C "iwr <raw-url>/scripts/setup-agent.ps1 \| iex"` |
| 自定义参数 | `./setup-agent.sh --password X --port 4096 --workdir /opt/myapp` |

### 6.3 路径占位符机制

任务文件使用占位符，`dispatch.sh` 根据目标机 OS 自动转换：

```markdown
---
title: 分析错误日志
machine: windows-build-01
---

请分析 {LOGDIR}/error.log 中的错误，
参考 {CONFDIR}/config.yaml 中的配置。
将报告写入 {REPORTS}/error-analysis.md。
```

dispatch.sh 内部转换逻辑：

```bash
declare -A path_map
if [[ "$target_os" == "windows" ]]; then
    path_map=(
        ["{LOGDIR}"]="C:\\ProgramData\\app\\logs"
        ["{CONFDIR}"]="C:\\ProgramData\\app\\config"
        ["{WORKDIR}"]="C:\\opencode-agent"
        ["{REPORTS}"]="C:\\opencode-agent\\reports"
    )
else
    path_map=(
        ["{LOGDIR}"]="/var/log/app"
        ["{CONFDIR}"]="/etc/myapp"
        ["{WORKDIR}"]="/opt/opencode-agent"
        ["{REPORTS}"]="/opt/opencode-agent/reports"
    )
fi
```

### 6.4 Controller 端 machines.json（混合平台）

```json
{
  "deploy-linux-01": {
    "url": "http://100.64.0.2:4096",
    "password": "secret",
    "labels": ["production", "app-server"],
    "os": "linux",
    "workdir": "/opt/myapp",
    "path_map": {
      "{LOGDIR}": "/var/log/app",
      "{CONFDIR}": "/etc/myapp"
    }
  },
  "deploy-win-01": {
    "url": "http://192.168.1.50:4096",
    "password": "secret",
    "labels": ["production", "build-server"],
    "os": "windows",
    "workdir": "C:\\opencode-agent",
    "path_map": {
      "{LOGDIR}": "C:\\ProgramData\\app\\logs",
      "{CONFDIR}": "C:\\ProgramData\\app\\config"
    }
  }
}
```

### 6.5 Windows 特别注意

1. **Node.js 路径**：`opencode.cmd` 而非 `opencode`（npm 全局安装后在 `%APPDATA%\npm\`）
2. **System environment variables**：需管理员权限设置，`setup-agent.ps1` 自动提升
3. **防火墙**：`netsh advfirewall` 放行 serve 端口
4. **路径兼容**：OpenCode 是 Node.js 应用，Windows 上正斜杠和反斜杠均可接受
5. **PowerShell 执行策略**：可能需要 `Set-ExecutionPolicy RemoteSigned`
6. **重试策略**：Windows 计划任务不支持秒级重启间隔，推荐 NSSM

---

## 7. 故障处理

### 7.1 任务挂起检测

```
Heartbeat 流程:
  每次收到事件 → 重置 timer(300s)
  timer 到期 → 检查 session status
    状态为 busy 超 300s → 判定为挂起
      → 发 SIGTERM 给对应 session (POST /session/{id}/abort)
      → 记录挂起点（最后收到的事件）
      → 可选：自动重试（最多 3 次）
      → 通知用户
```

### 7.2 部署机不可达

```
dispatch.sh 逻辑:
  1. POST /global/health → 超时 5s → 标记不可达
  2. 重试 3 次（间隔 10s）
  3. 仍不可达 → 跳过该机器 + 通知
  4. 定期重连检测（cron: */5 * * * *）
```

### 7.3 权限拒绝回退

如果 session preset 覆盖权限导致 `question`/`plan_enter` 被 deny：
- Controller 检测到 SSE 中出现 `permission.updated` 事件
- 自动发送 `permission.reply` 允许操作
- 或：prompt 中内置 "不要进入 plan mode，不要提问" 指令

---

> 📅 最后更新：2026-06-11
>
> 🤖 本文档由 Claude (claude.ai/code) 辅助整理
