# OpenCode 无人值守与持续对话指南

OpenCode 零交互、不间断任务执行的完整配置方案。覆盖权限消除、Session 管理、远程任务分发、心跳监控和 Windows/Linux 双平台部署。

## 快速开始

```bash
# 1. 配置全局放行权限
echo '{"permission": {"*": "allow", "question": "allow", "plan_enter": "allow", "plan_exit": "allow"}}' > opencode.json

# 2. 非交互执行单次任务（使用 --format json 获取 session_id）
opencode run --format json "你的任务" 2>/tmp/stderr.log | tee /tmp/events.ndjson
SESSION_ID=$(head -1 /tmp/events.ndjson | jq -r '.sessionID')

# 3. 多轮持续对话
opencode run --format json --session "$SESSION_ID" "继续深入..."
```

## 文档导航

| 文档 | 内容 |
|------|------|
| [opencode-unattended-continuous-guide.md](opencode-unattended-continuous-guide.md) | 基础指南：权限配置、Session 管理、CI/CD、坑点规避 |
| [opencode-remote-dispatch-design.md](opencode-remote-dispatch-design.md) | 远程分发架构：心跳监控、Serve API、Windows+Linux 双平台、完整部署流程 |

## 脚本工具

| 脚本 | 用途 | 平台 |
|------|------|------|
| `scripts/run-with-heartbeat.sh` | `opencode run` 包装器，带心跳监控和报告生成 | Linux/macOS |
| `scripts/heartbeat.sh` | NDJSON 事件流心跳监控，超时告警 | Linux/macOS |
| `scripts/dispatch.sh` | 远程任务分发控制器（push/status/report/health） | Linux/macOS |
| `scripts/setup-agent.sh` | 部署机一键安装（systemd 托管） | Linux/macOS |
| `scripts/setup-agent.ps1` | 部署机一键安装（NSSM/Task Scheduler 托管） | Windows |

## 部署机一键安装

```bash
# Linux 部署机
curl -sL https://raw.githubusercontent.com/L-ingqin12/opencode-unattended-guide/main/scripts/setup-agent.sh | bash

# Windows 部署机
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/L-ingqin12/opencode-unattended-guide/main/scripts/setup-agent.ps1 | iex"
```

## 架构概览

```
Controller (调度机)
    │
    ├─ dispatch.sh ──→ 部署机 A (Linux)   ← opencode serve :4096
    │                 部署机 B (Windows)  ← opencode serve :4096
    │
    └─ heartbeat.sh ──→ 本地监控 NDJSON 事件流 / SSE 事件流
```

## 许可

MIT
