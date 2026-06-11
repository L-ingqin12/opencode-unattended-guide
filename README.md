# OpenCode 无人值守完整方案

OpenCode 零交互、不间断任务执行的生产级配置方案。覆盖本地自动化、远程任务分发、大文件在线分析、安全加固。

## 核心理念

> **如无必要，勿增实体。** 核心只有一件事——把任务发给 `opencode serve`，等它跑完，拿结果。其他所有层按需叠加。

## 30 秒开始

```bash
# ── 在目标机（部署机）上 ──
./otask.sh setup                     # Linux/macOS 一键安装
# 或安全加固版（Agent 白名单 + 目录沙箱）:
./otask.sh secure

# Windows:
.\otask.ps1 setup                    # 管理员 PowerShell
.\otask.ps1 secure                   # 安全加固版

# ── 在控制器上（任意机器） ──
export OTASK_TARGET=192.168.1.50:4096
./otask.sh run tasks/log-analysis.md            # 提交任务文件
./otask.sh send "分析 /var/log/app/error.log"    # 快速一句
./otask.sh continue ses_xxx "继续深入分析"       # 多轮对话

# Windows:
$env:OTASK_TARGET = "192.168.1.50:4096"
.\otask.ps1 run tasks\log-analysis.md
```

## 仓库结构

```
opencode-unattended-guide/
│
├── otask.sh / otask.ps1                ★ 核心工具 — 跨平台任务生命周期
│                                         run send status result continue abort setup secure
│
├── opencode-unattended-continuous-guide.md  # 基础指南 (权限/Session/CI)
├── opencode-remote-dispatch-design.md       # 架构设计 (serve/nginx/安全通道)
├── opencode-practical-patterns.md           # 实操专题 (web vs serve / 大文件 / URL)
│
├── tasks/                                   # 任务模板（开箱即用）
│   ├── log-analysis.md                      # 日志错误分析
│   ├── archive-analysis.md                  # 归档压缩包批量分析
│   └── health-check.md                      # 系统健康检查
│
├── config/
│   ├── secure-opencode.json                 # Agent 白名单 + 目录沙箱
│   └── agent-security-guide.md              # 三层安全防护文档
│
├── nginx/                                   # 可选：nginx 接入层
│   ├── opencode-upstream.conf               # rate limit / TLS / SSE
│   └── README.md
│
└── scripts/                                 # 可选：扩展工具
    ├── setup-agent.sh / setup-agent.ps1     # 部署机一键安装
    ├── heartbeat.sh                         # 带 NDJSON 解析的心跳监控
    ├── dispatch.sh                          # 多机批量分发
    └── run-with-heartbeat.sh                # 本地 run 包装器
```

## 从简到繁：按需选取

| 你的场景 | 你需要的东西 | 复杂度 |
|----------|-------------|--------|
| 单机自动执行 | `otask.sh` | ★ |
| 多轮持续对话 | `otask.sh continue` | ★ |
| 远程提交到部署机 | `otask.sh` + `opencode serve` | ★★ |
| 分析 GB 级日志/压缩包 | `otask.sh run tasks/log-analysis.md` | ★★ |
| 人在浏览器里操作 | `opencode web --port 4096` | ★★ |
| 限制 Agent 暴露面 | `otask.sh secure` | ★★ |
| 暴露到公网 | + `nginx/` (TLS + rate limit) | ★★★ |
| CI/CD 集成 | `otask.sh run` in pipeline | ★★ |
| 多用户隔离 | Docker 每用户独立容器 | ★★★ |
| 高安全环境 | + mTLS + systemd 沙箱 | ★★★★ |

## 三种模式对比

| 模式 | 命令 | 谁用 | 场景 |
|------|------|------|------|
| **CLI 一次性** | `opencode run --format json "task"` | 脚本/CI | 单次执行，自动退出 |
| **Headless 服务** | `opencode serve --port 4096` | 程序/otask | 远程 API 调用，持续运行 |
| **Web 界面** | `opencode web --port 4096` | 人/浏览器 | 手动操作，可视化 |

## 访问控制三层模型

```
L1: Nginx (IP 白名单 / rate limit / TLS / mTLS)    ← 网络层
L2: opencode.json (Agent 白名单 / 路径沙箱 / cmd 白名单) ← 应用层
L3: 会话隔离 (独立端口 / Docker 容器)                ← 数据层
```

详见 [config/agent-security-guide.md](config/agent-security-guide.md)

## 许可

MIT
