#!/bin/bash
# ==================================================================
# otask — OpenCode 任务最小生命周期管理
#
# 设计原则：如无必要勿增实体。
# 核心只有一件事——把任务发给 opencode serve，等它跑完，拿结果。
#
# 用法:
#   otask run <task-file>    [-t host:port]          # 提交任务并等待完成
#   otask send "<prompt>"    [-t host:port] [-d dir]  # 快速发送一句 prompt
#   otask status <sid>       [-t host:port]           # 查看 session 状态
#   otask result <sid>       [-t host:port]           # 获取 session 结果
#   otask continue <sid>     [-t host:port] "<prompt>" # 继续已有 session
#   otask sessions           [-t host:port]           # 列出活跃 sessions
#   otask abort <sid>        [-t host:port]           # 中断 session
#
# 目标机设置:
#   otask setup  [-p password] [-w /opt/app]          # 在本机安装并启动 serve
#   otask secure [-p password] [-w /opt/app]          # 安装 + 安全加固配置
#   (Windows: otask.ps1 setup / otask.ps1 secure)
#
# 示例:
#   otask run ./tasks/analyze-errors.md -t 192.168.1.50:4096
#   otask send "分析 /var/log/app/error.log" -t prod-01:4096 -d /opt/myapp
#   otask continue ses_xxx "继续深入分析" -t prod-01:4096
# ==================================================================

set -euo pipefail

# ── 默认配置 ──────────────────────────────────
OTASK_TARGET="${OTASK_TARGET:-127.0.0.1:4096}"
OTASK_PASSWORD="${OTASK_PASSWORD:-}"
OTASK_TIMEOUT="${OTASK_TIMEOUT:-600}"
OTASK_POLL="${OTASK_POLL:-2}"

# ── 参数解析 ──────────────────────────────────
cmd="${1:-}"
shift 2>/dev/null || true

TARGET="$OTASK_TARGET"
WORKDIR=""
AGENT="build"
MODEL="anthropic/claude-sonnet-4"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET="$2"; shift 2 ;;
        -d|--dir)    WORKDIR="$2"; shift 2 ;;
        -a|--agent)  AGENT="$2"; shift 2 ;;
        -m|--model)  MODEL="$2"; shift 2 ;;
        -p|--password) OTASK_PASSWORD="$2"; shift 2 ;;
        *) break ;;
    esac
done

# ── HTTP 辅助 ──────────────────────────────────
http() {
    local method="$1" path="$2" data="${3:-}"
    local auth=()
    [ -n "$OTASK_PASSWORD" ] && auth=(-u "agent:$OTASK_PASSWORD")
    curl -s --max-time 30 "${auth[@]}" -X "$method" "http://$TARGET$path" \
        -H 'Content-Type: application/json' ${data:+-d "$data"}
}

# ── 确保目标可达 ──────────────────────────────
ensure_up() {
    if ! http GET "/global/health" | jq -e '.healthy == true' > /dev/null 2>&1; then
        echo "❌ 目标不可达: $TARGET" >&2
        echo "   请确认目标机上 opencode serve 已启动" >&2
        echo "   或在目标机上运行: otask setup" >&2
        exit 1
    fi
}

# ── 等待任务完成 ──────────────────────────────
await() {
    local sid="$1"
    local start elapsed status
    start=$(date +%s)

    echo "⏳ 等待完成..." >&2
    while true; do
        elapsed=$(($(date +%s) - start))
        status=$(http GET "/session/status" | jq -r ".sessions.\"$sid\".type // \"unknown\"" 2>/dev/null)

        case "$status" in
            idle)
                printf "\r✅ 完成 (${elapsed}s)\n" >&2
                return 0
                ;;
            busy|retry)
                printf "\r   %-6s %ds / %ds" "$status" "$elapsed" "$OTASK_TIMEOUT" >&2
                ;;
            *)
                echo "" >&2
                echo "⚠️  未知状态: $status" >&2
                ;;
        esac

        if [ "$elapsed" -gt "$OTASK_TIMEOUT" ]; then
            echo "" >&2
            echo "⏰ 超时 (${OTASK_TIMEOUT}s)，正在中断..." >&2
            http POST "/session/$sid/abort" > /dev/null 2>&1 || true
            return 1
        fi
        sleep "$OTASK_POLL"
    done
}

# ── 命令实现 ──────────────────────────────────

cmd_run() {
    local task_file="${1:?用法: otask run <task-file.md> [-t host:port]}"
    [ -f "$task_file" ] || { echo "❌ 文件不存在: $task_file" >&2; exit 1; }

    ensure_up

    # 解析 YAML frontmatter
    local title dir_override
    title=$(sed -n '/^---$/,/^---$/p' "$task_file" | sed -n 's/^title: *//p')
    dir_override=$(sed -n '/^---$/,/^---$/p' "$task_file" | sed -n 's/^directory: *//p')
    [ -n "$dir_override" ] && WORKDIR="$dir_override"

    # 提取正文
    local body
    body=$(sed '1{/^---$/!q}; /^---$/,/^---$/d' "$task_file")
    [ -z "$body" ] && { echo "❌ 任务文件内容为空" >&2; exit 1; }

    echo "🚀 任务: ${title:-未命名}" >&2
    echo "   目标: $TARGET  目录: ${WORKDIR:-默认}" >&2

    # 创建 session
    local sid
    sid=$(http POST "/session" "{\"directory\":\"${WORKDIR:-/tmp}\"}" | jq -r '.id // empty')
    [ -z "$sid" ] && { echo "❌ 创建 session 失败" >&2; exit 1; }
    echo "   Session: $sid" >&2

    # 发送 prompt
    local prompt_json
    prompt_json=$(jq -n --arg agent "$AGENT" --arg model "${MODEL#*/}" --arg text "$body" '{
        agent: $agent,
        model: { providerID: "anthropic", modelID: $model },
        parts: [{ type: "text", text: $text }]
    }')
    http POST "/session/$sid/prompt" "$prompt_json" > /dev/null

    # 等待完成
    if await "$sid"; then
        # 输出结果
        local output
        output=$(http GET "/session/$sid/messages" | jq -r '
            [.[].parts[]? | select(.type == "text") | .text] | join("\n\n")
        ' 2>/dev/null)

        echo ""
        echo "═══════════════════════════════════════"
        echo "  📄 任务输出"
        echo "═══════════════════════════════════════"
        echo "$output"
        echo ""
        echo "── Session: $sid (已完成，可用 otask continue 继续)"

        # 同时输出 session id 方便脚本解析
        echo "OTASK_SESSION_ID=$sid"
    else
        echo "OTASK_SESSION_ID=$sid"
        exit 2
    fi
}

cmd_send() {
    local prompt="${1:?用法: otask send \"prompt\" [-t host:port] [-d dir]}"
    ensure_up

    echo "📤 发送: ${prompt:0:80}..." >&2

    local sid
    sid=$(http POST "/session" "{\"directory\":\"${WORKDIR:-/tmp}\"}" | jq -r '.id // empty')
    [ -z "$sid" ] && { echo "❌ 创建 session 失败" >&2; exit 1; }

    local prompt_json
    prompt_json=$(jq -n --arg agent "$AGENT" --arg model "${MODEL#*/}" --arg text "$prompt" '{
        agent: $agent,
        model: { providerID: "anthropic", modelID: $model },
        parts: [{ type: "text", text: $text }]
    }')
    http POST "/session/$sid/prompt" "$prompt_json" > /dev/null

    await "$sid" && cmd_result "$sid" || true
}

cmd_status() {
    local sid="${1:?用法: otask status <session-id> [-t host:port]}"
    ensure_up

    local status
    status=$(http GET "/session/status" | jq -r ".sessions.\"$sid\" // {}")
    echo "$status" | jq '.'
}

cmd_result() {
    local sid="${1:?用法: otask result <session-id> [-t host:port]}"
    ensure_up

    http GET "/session/$sid/messages" | jq -r '
        [.[].parts[]? | select(.type == "text") | .text] | join("\n\n")
    ' 2>/dev/null
}

cmd_continue() {
    local sid="${1:?用法: otask continue <session-id> \"prompt\" [-t host:port]}"
    local prompt="${2:?}"
    ensure_up

    echo "📎 继续: $sid" >&2

    local prompt_json
    prompt_json=$(jq -n --arg agent "$AGENT" --arg model "${MODEL#*/}" --arg text "$prompt" '{
        agent: $agent,
        model: { providerID: "anthropic", modelID: $model },
        parts: [{ type: "text", text: $text }]
    }')
    http POST "/session/$sid/prompt" "$prompt_json" > /dev/null

    await "$sid" && cmd_result "$sid" || true
}

cmd_sessions() {
    ensure_up
    echo "📋 $TARGET 活跃 sessions:" >&2
    http GET "/session/status" | jq '.sessions // {}'
}

cmd_abort() {
    local sid="${1:?用法: otask abort <session-id> [-t host:port]}"
    ensure_up
    http POST "/session/$sid/abort"
    echo "🛑 已中断: $sid"
}

cmd_secure() {
    # ── 安全加固版 setup ────────────────────
    # 与 setup 相同但使用 secure-opencode.json（Agent 白名单 + 目录沙箱）
    local password="${OTASK_PASSWORD:-auto-$(openssl rand -hex 16 2>/dev/null || echo 'changeme')}"
    local port="${OTASK_TARGET#*:}"; port="${port##*:}"; [ "$port" = "$OTASK_TARGET" ] && port="4096"
    local wdir="${WORKDIR:-/opt/opencode-agent}"

    echo "═══════════════════════════════════════"
    echo "  otask secure — 安全加固安装"
    echo "═══════════════════════════════════════"
    echo "  仅暴露 analyzer agent，沙箱限定工作目录"
    echo "  端口: $port  目录: $wdir"
    echo ""

    command -v opencode > /dev/null 2>&1 || npm install -g opencode
    mkdir -p "$wdir"/{reports,logs}

    # 部署安全配置（Agent 白名单 + 路径沙箱）
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/config/secure-opencode.json" ]; then
        cp "$SCRIPT_DIR/config/secure-opencode.json" "$wdir/opencode.json"
        echo "✅ secure-opencode.json → $wdir/opencode.json"
    else
        # 内联安全配置
        cat > "$wdir/opencode.json" << 'EOFSECURE'
{"default_agent":"analyzer","agent":{"analyzer":{"mode":"primary","permission":{"read":{"/var/log/**":"allow","/opt/**":"allow","*":"deny"},"edit":{"/opt/opencode-agent/reports/**":"allow","*":"deny"},"bash":{"cat *":"allow","grep *":"allow","find *":"allow","ls *":"allow","head *":"allow","tail *":"allow","wc *":"allow","sort *":"allow","df *":"allow","free *":"allow","du *":"allow","ps *":"allow","systemctl status *":"allow","*":"deny"},"task":"deny","webfetch":"deny","websearch":"deny","question":"deny","plan_enter":"deny","plan_exit":"deny"}}},"permission":{"*":"deny"}}
EOFSECURE
        echo "✅ 内联安全配置"
    fi

    export OPENCODE_SERVER_PASSWORD="$password"
    export OPENCODE_DISABLE_AUTOUPDATE=true

    if command -v systemctl > /dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
        cat > /etc/systemd/system/opencode-agent.service << EOF
[Unit]
Description=OpenCode Agent (Secure)
After=network.target
[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$wdir
Environment="OPENCODE_SERVER_PASSWORD=$password"
Environment="OPENCODE_DISABLE_AUTOUPDATE=true"
ExecStart=$(which opencode) serve --port $port --hostname 0.0.0.0
Restart=always
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$wdir /var/log
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now opencode-agent
        echo "✅ systemd 服务已启动 (systemd 安全加固: NoNewPrivileges, ProtectSystem=strict)"
    else
        opencode serve --port "$port" --hostname 0.0.0.0 &
        echo "✅ 后台启动 (PID $!)"
    fi

    echo ""
    echo "🔒 安全配置摘要:"
    echo "   - 仅暴露: analyzer agent"
    echo "   - 沙箱目录: $wdir"
    echo "   - bash 白名单: 仅诊断命令"
    echo "   - 子 agent: 禁止"
    echo "   - 外网访问: 禁止 (webfetch/websearch)"
    echo "   - 计划模式: 禁止"
}

cmd_setup() {
    # ── 在本机安装并启动 opencode serve ────────
    local password="${OTASK_PASSWORD:-auto-$(openssl rand -hex 8 2>/dev/null || echo 'changeme')}"
    local port="${OTASK_TARGET#*:}"; port="${port##*:}"; [ "$port" = "$OTASK_TARGET" ] && port="4096"
    local wdir="${WORKDIR:-/opt/opencode-agent}"

    echo "═══════════════════════════════════════"
    echo "  otask setup — 本机 Agent 安装"
    echo "═══════════════════════════════════════"
    echo "  端口: $port  密码: $password"
    echo "  目录: $wdir"
    echo ""

    # 安装 opencode
    command -v opencode > /dev/null 2>&1 || npm install -g opencode

    # 目录
    mkdir -p "$wdir"/{reports,logs}

    # 权限
    cat > "$wdir/opencode.json" << EOF
{"permission":{"*":"allow","question":"allow","plan_enter":"allow","plan_exit":"allow"}}
EOF
    echo "✅ opencode.json (allow-all)"

    # 环境
    export OPENCODE_SERVER_PASSWORD="$password"
    export OPENCODE_DISABLE_AUTOUPDATE=true

    # 启动
    if command -v systemctl > /dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
        cat > /etc/systemd/system/opencode-agent.service << EOF
[Unit]
Description=OpenCode Agent
After=network.target
[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$wdir
Environment="OPENCODE_SERVER_PASSWORD=$password"
Environment="OPENCODE_DISABLE_AUTOUPDATE=true"
ExecStart=$(which opencode) serve --port $port --hostname 0.0.0.0
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now opencode-agent
        echo "✅ systemd 服务已启动"
    else
        opencode serve --port "$port" --hostname 0.0.0.0 &
        echo "✅ 后台启动 (PID $!)"
    fi

    echo ""
    echo "── 配置 ──"
    echo "export OTASK_TARGET=$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1'):$port"
    echo "export OTASK_PASSWORD=$password"
    echo ""
    echo "测试: curl http://localhost:$port/global/health"
}

# ── 入口 ──────────────────────────────────────
case "$cmd" in
    run)      cmd_run "$@" ;;
    send)     cmd_send "$@" ;;
    status)   cmd_status "$@" ;;
    result)   cmd_result "$@" ;;
    continue) cmd_continue "$@" ;;
    sessions) cmd_sessions ;;
    abort)    cmd_abort "$@" ;;
    setup)    cmd_setup ;;
    secure)   cmd_secure ;;
    *)
        echo "otask — OpenCode 任务管理" >&2
        echo "" >&2
        echo "用法:" >&2
        echo "  otask run    <task.md>   [-t host:port] [-d dir]  提交任务文件并等待完成" >&2
        echo "  otask send   \"<prompt>\"  [-t host:port] [-d dir]  快速发送 prompt" >&2
        echo "  otask status <sid>       [-t host:port]            查看状态" >&2
        echo "  otask result <sid>       [-t host:port]            获取结果" >&2
        echo "  otask continue <sid> \"<prompt>\" [-t host:port]     继续会话" >&2
        echo "  otask sessions           [-t host:port]            列出活跃会话" >&2
        echo "  otask abort   <sid>      [-t host:port]            中断任务" >&2
        echo "  otask setup   [-p password] [-d dir]               本机安装并启动 serve" >&2
        echo "  otask secure  [-p password] [-d dir]               安全加固版 setup" >&2
        echo "" >&2
        echo "环境变量:" >&2
        echo "  OTASK_TARGET=host:port   默认目标机" >&2
        echo "  OTASK_PASSWORD=xxx       认证密码" >&2
        echo "  OTASK_TIMEOUT=600        超时秒数" >&2
        exit 1
        ;;
esac
