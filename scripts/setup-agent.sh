#!/bin/bash
# ============================================================
# setup-agent.sh — 部署机 OpenCode Agent 一键安装 (Linux/macOS)
#
# 在每台 Linux/macOS 部署机上执行:
#   curl -sL https://raw.githubusercontent.com/L-ingqin12/opencode-unattended-guide/main/scripts/setup-agent.sh | bash
#
# Windows 部署机请使用:
#   powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/L-ingqin12/opencode-unattended-guide/main/scripts/setup-agent.ps1 | iex"
#
# 或指定参数:
#   ./setup-agent.sh --password mysecret --port 4096 --workdir /opt/myapp
# ============================================================

set -euo pipefail

# —— OS 检测 ——
case "$(uname -s 2>/dev/null || echo 'unknown')" in
    Linux|Darwin)
        echo "✅ OS: $(uname -s) — 使用 bash 安装"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "⚠️  检测到 Windows 环境 (Git Bash/WSL)"
        echo "   推荐使用 PowerShell 版本: .\setup-agent.ps1"
        echo "   或继续在 Git Bash 中安装（部分功能受限）..."
        echo ""
        ;;
    *)
        echo "⚠️  未识别的 OS，尝试继续..."
        ;;
esac

PASSWORD="${OPENCODE_SERVER_PASSWORD:-auto-$(openssl rand -hex 12)}"
PORT="${OPENCODE_SERVER_PORT:-4096}"
WORKDIR="${OPENCODE_WORKDIR:-/opt/opencode-agent}"
AGENT_USER="${OPENCODE_AGENT_USER:-$(whoami)}"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --password) PASSWORD="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --workdir)  WORKDIR="$2"; shift 2 ;;
        --user)     AGENT_USER="$2"; shift 2 ;;
        *)          echo "未知参数: $1"; exit 1 ;;
    esac
done

echo "══════════════════════════════════════════════"
echo "  OpenCode Agent 部署机安装"
echo "══════════════════════════════════════════════"
echo "  用户:     $AGENT_USER"
echo "  工作目录: $WORKDIR"
echo "  端口:     $PORT"
echo ""

# —— 1. 检查 opencode ——
if ! command -v opencode &>/dev/null; then
    echo "📦 安装 OpenCode..."
    npm install -g opencode
else
    echo "✅ OpenCode 已安装: $(opencode --version 2>/dev/null || echo 'unknown')"
fi

# —— 2. 创建工作目录 ——
mkdir -p "$WORKDIR"/{reports,logs,tasks}
echo "✅ 工作目录: $WORKDIR"

# —— 3. 权限配置 ——
cat > "$WORKDIR/opencode.json" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
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
EOF
echo "✅ 权限配置: allow all"

# —— 4. 环境配置 ——
ENV_FILE="$WORKDIR/.env"
cat > "$ENV_FILE" << EOF
OPENCODE_SERVER_PASSWORD=$PASSWORD
OPENCODE_DISABLE_AUTOUPDATE=true
OPENCODE_DISABLE_WATCHER=true
OPENCODE_WORKDIR=$WORKDIR
EOF
chmod 600 "$ENV_FILE"
echo "✅ 环境文件: $ENV_FILE (权限 600)"

# —— 5. systemd 服务 ——
SERVICE_FILE="/etc/systemd/system/opencode-agent.service"
if [ "$(id -u)" -eq 0 ]; then
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=OpenCode Agent Server
After=network.target

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$WORKDIR
EnvironmentFile=$ENV_FILE
ExecStart=$(which opencode) serve --port $PORT --hostname 0.0.0.0
Restart=always
RestartSec=10

# 安全加固（可选）
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable opencode-agent
    systemctl start opencode-agent
    echo "✅ systemd 服务已启动"
    echo ""
    echo "管理命令:"
    echo "  systemctl status opencode-agent"
    echo "  journalctl -u opencode-agent -f"
else
    echo "⚠️  非 root 用户，跳过 systemd 配置。手动启动:"
    echo ""
    echo "  source $ENV_FILE"
    echo "  opencode serve --port $PORT --hostname 0.0.0.0 &"
fi

# —— 6. 示例自定义 agent ——
AGENT_DIR="$HOME/.config/opencode/agent"
mkdir -p "$AGENT_DIR"
cat > "$AGENT_DIR/analyzer.md" << 'EOF'
---
name: analyzer
description: 日志和系统状态分析专家 — 可访问本机文件、日志和执行诊断命令
mode: primary
permission: allow
---
你是一台部署机上的日志和系统状态分析专家。

你可以:
- 读取本机上的任意日志文件
- 执行诊断命令 (systemctl status, df -h, free -m, top -bn1, etc.)
- 读取配置文件
- 分析错误模式并给出修复建议

操作原则:
1. 所有命令使用非交互标志
2. 不要进入 plan mode，直接执行
3. 不要询问问题，自行决策
4. 分析结果写入 /opt/opencode-agent/reports/ 目录
EOF
echo "✅ 自定义 agent: analyzer"

# —— 7. 输出摘要 ——
echo ""
echo "══════════════════════════════════════════════"
echo "  ✅ 安装完成"
echo "══════════════════════════════════════════════"
echo ""
echo "  Serve URL:  http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):$PORT"
echo "  Password:   $PASSWORD"
echo "  Workdir:    $WORKDIR"
echo ""
echo "  健康检查:"
echo "    curl http://localhost:$PORT/global/health"
echo ""
echo "  Controller 端配置 (machines.json):"
echo "    {"
echo "      \"$(hostname)\": {"
echo "        \"url\": \"http://<本机IP>:$PORT\","
echo "        \"password\": \"$PASSWORD\","
echo "        \"labels\": [\"production\"],"
echo "        \"workdir\": \"$WORKDIR\""
echo "      }"
echo "    }"
echo ""
