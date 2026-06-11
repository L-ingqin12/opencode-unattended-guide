# OpenCode 无人值守完整方案

OpenCode 零交互、不间断任务执行的生产级配置方案。覆盖本地自动化、远程任务分发、安全加固。

## 核心理念

> **如无必要，勿增实体。** 核心只有一件事——把任务发给 `opencode serve`，等它跑完，拿结果。其他所有层按需叠加。

## 30 秒开始

```bash
# 在目标机（部署机）上
./otask.sh setup                     # 安装 + 启动 opencode serve
# 或安全加固版:
./otask.sh secure                    # Agent 白名单 + 目录沙箱

# 在控制器上
export OTASK_TARGET=192.168.1.50:4096
./otask.sh send "分析 /var/log/app/error.log" -d /opt/myapp
./otask.sh result ses_xxx           # 获取结果
./otask.sh continue ses_xxx "深入分析错误原因"
```

## 仓库结构

```
opencode-unattended-guide/
│
├── otask.sh                              ★ 核心工具 — 任务生命周期管理
│                                         (run/send/status/result/continue/setup/secure)
│
├── opencode-unattended-continuous-guide.md  # 基础指南
├── opencode-remote-dispatch-design.md       # 架构设计
│
├── config/
│   ├── secure-opencode.json                 # Agent 白名单 + 目录沙箱
│   └── agent-security-guide.md              # 三层安全防护
│
├── nginx/                                   # 可选：nginx 接入层
│   ├── opencode-upstream.conf               # rate limit / TLS / SSE
│   ├── nginx-http-block.conf
│   └── README.md
│
└── scripts/                                 # 可选：辅助脚本
    ├── setup-agent.sh                       # Linux 一键安装
    ├── setup-agent.ps1                      # Windows 一键安装
    ├── heartbeat.sh                         # 心跳监控
    ├── dispatch.sh                          # 批量分发
    └── run-with-heartbeat.sh                # run 包装器
```

## 从简到繁：按需选取

| 你的场景 | 你需要的东西 |
|----------|-------------|
| 单机自动执行任务 | `otask.sh` + `opencode.json` (allow-all) |
| 多轮持续对话 | `otask.sh continue` |
| 远程提交到部署机 | `otask.sh` + `opencode serve` on target |
| 多台部署机 | `otask.sh` + `export OTASK_TARGET=ip:port` |
| 限制 Agent 暴露面 | `otask.sh secure` → Agent 白名单 + 目录沙箱 |
| 暴露到外网 | + `nginx/opencode-upstream.conf` (TLS + rate limit) |
| CI/CD 集成 | `otask.sh run` in GitHub Actions / Jenkins |
| 多用户隔离 | Docker 每用户独立容器 / 独立端口 |
| 高安全环境 | + mTLS (nginx ssl_verify_client) + systemd 沙箱 |

## 访问控制三层模型

```
L1: Nginx (IP 白名单 / rate limit / TLS / mTLS)    ← 网络层
L2: opencode.json (Agent 白名单 / 路径沙箱 / cmd 白名单) ← 应用层
L3: 会话隔离 (独立端口 / Docker 容器)                ← 数据层
```

详见 [config/agent-security-guide.md](config/agent-security-guide.md)

## 许可

MIT
