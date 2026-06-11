#!/bin/bash
# ============================================================
# dispatch.sh — OpenCode 远程任务分发控制器
#
# 用法:
#   dispatch.sh push <machine> <task-file.md>    # 分发单个任务
#   dispatch.sh push-all <label> <task-file.md>  # 按标签群发
#   dispatch.sh status <machine>                 # 查看机器所有 session 状态
#   dispatch.sh report <machine> <session-id>    # 拉取任务报告
#   dispatch.sh health                           # 检查所有机器健康状态
#   dispatch.sh list-machines                    # 列出所有机器
#   dispatch.sh abort <machine> <session-id>     # 中断指定 session
#
# 前置:
#   1. 目标机已运行 opencode serve
#   2. ~/opencode-controller/machines.json 已配置
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTROLLER_DIR="${OPENCODE_CONTROLLER_DIR:-$HOME/opencode-controller}"
MACHINES_FILE="$CONTROLLER_DIR/machines.json"
TASKS_DIR="$CONTROLLER_DIR/tasks"
REPORTS_DIR="$CONTROLLER_DIR/reports"
LOGS_DIR="$CONTROLLER_DIR/logs"

# —— 初始化 ——
init() {
    mkdir -p "$CONTROLLER_DIR"/{tasks,reports,scripts,logs}
    if [ ! -f "$MACHINES_FILE" ]; then
        cat > "$MACHINES_FILE" << 'EOF'
{
  "deploy-prod-01": {
    "url": "http://127.0.0.1:4096",
    "password": "",
    "labels": ["production"],
    "workdir": "/opt/myapp"
  }
}
EOF
        echo "⚠️  已生成默认 $MACHINES_FILE，请编辑后使用"
    fi
}

# —— 获取机器配置 ——
get_machine() {
    local name="$1"
    jq -r ".[\"$name\"] // empty" "$MACHINES_FILE"
}

get_machines_by_label() {
    local label="$1"
    jq -r "to_entries[] | select(.value.labels[]? == \"$label\") | .key" "$MACHINES_FILE"
}

# —— HTTP 辅助 ——
api_call() {
    local url="$1" method="$2" endpoint="$3" data="${4:-}"
    local password
    password=$(echo "$MACHINE_CONFIG" | jq -r '.password // ""')

    local auth_header=""
    if [ -n "$password" ]; then
        auth_header="-u agent:$password"
    fi

    if [ -n "$data" ]; then
        curl -s --max-time 30 $auth_header -X "$method" "$url$endpoint" \
            -H 'Content-Type: application/json' \
            -d "$data"
    else
        curl -s --max-time 30 $auth_header -X "$method" "$url$endpoint"
    fi
}

# —— 命令实现 ——

cmd_push() {
    local machine="$1" task_file="$2"

    if [ ! -f "$task_file" ]; then
        echo "❌ 任务文件不存在: $task_file"
        exit 1
    fi

    MACHINE_CONFIG=$(get_machine "$machine")
    if [ -z "$MACHINE_CONFIG" ]; then
        echo "❌ 未知机器: $machine (可用: $(jq -r 'keys[]' "$MACHINES_FILE" | tr '\n' ' '))"
        exit 1
    fi

    local url workdir
    url=$(echo "$MACHINE_CONFIG" | jq -r '.url')
    workdir=$(echo "$MACHINE_CONFIG" | jq -r '.workdir // "/tmp"')

    # 解析任务文件 frontmatter
    local title agent model timeout workdir_override
    title=$(sed -n '/^---$/,/^---$/p' "$task_file" | grep '^title:' | cut -d: -f2- | xargs)
    agent=$(sed -n '/^---$/,/^---$/p' "$task_file" | grep '^agent:' | cut -d: -f2- | xargs)
    model=$(sed -n '/^---$/,/^---$/p' "$task_file" | grep '^model:' | cut -d: -f2- | xargs)
    timeout=$(sed -n '/^---$/,/^---$/p' "$task_file" | grep '^timeout:' | cut -d: -f2- | xargs)
    workdir_override=$(sed -n '/^---$/,/^---$/p' "$task_file" | grep '^directory:' | cut -d: -f2- | xargs)

    [ -n "$workdir_override" ] && workdir="$workdir_override"
    [ -z "$agent" ] && agent="build"
    [ -z "$model" ] && model="anthropic/claude-sonnet-4"
    [ -z "$timeout" ] && timeout=600

    # 提取任务正文（去掉 YAML frontmatter）
    local prompt_text
    prompt_text=$(sed '1{/^---$/!q}; /^---$/,/^---$/d' "$task_file")

    echo "🚀 分发任务到 $machine"
    echo "   URL:      $url"
    echo "   Agent:    $agent"
    echo "   Model:    $model"
    echo "   Workdir:  $workdir"
    echo "   Timeout:  ${timeout}s"

    # Step 1: Health check
    local health
    health=$(curl -s --max-time 5 "$url/global/health" 2>/dev/null || echo '{"healthy":false}')
    if [ "$(echo "$health" | jq -r '.healthy // false')" != "true" ]; then
        echo "❌ 目标机不可达: $url"
        exit 2
    fi
    echo "   ✅ 健康检查通过"

    # Step 2: 创建 session
    local session_resp
    session_resp=$(api_call "$url" "POST" "/session" \
        "{\"directory\":\"$workdir\"}")

    local session_id
    session_id=$(echo "$session_resp" | jq -r '.id // empty')

    if [ -z "$session_id" ]; then
        echo "❌ 创建 session 失败: $session_resp"
        exit 3
    fi
    echo "   📎 Session: $session_id"

    # Step 3: 发送 prompt
    local prompt_json
    prompt_json=$(jq -n \
        --arg agent "$agent" \
        --arg model "$model" \
        --arg text "$prompt_text" \
        '{
            agent: $agent,
            model: { providerID: "anthropic", modelID: ($model | split("/")[1]) },
            parts: [{ type: "text", text: $text }]
        }')

    local prompt_resp
    prompt_resp=$(api_call "$url" "POST" "/session/$session_id/prompt" "$prompt_json")
    echo "   📤 任务已提交"

    # Step 4: 轮询状态（心跳）
    echo "   ⏳ 等待执行..."
    local start_time elapsed status
    start_time=$(date +%s)

    while true; do
        status=$(api_call "$url" "GET" "/session/status" "" | jq -r ".sessions.\"$session_id\".type // \"unknown\"")
        elapsed=$(($(date +%s) - start_time))

        case "$status" in
            idle)
                echo "   ✅ 完成 (${elapsed}s)"
                break
                ;;
            busy|retry)
                printf "\r   ⏳ %s... (%ds/%ds)" "$status" "$elapsed" "$timeout"
                sleep 2
                ;;
            *)
                echo "   ⚠️ 未知状态: $status"
                sleep 5
                ;;
        esac

        if [ "$elapsed" -gt "$timeout" ]; then
            echo ""
            echo "   ⏰ 超时，正在中断..."
            api_call "$url" "POST" "/session/$session_id/abort" "" > /dev/null 2>&1 || true
            echo "   ❌ 超时 ($timeout s)"
            exit 4
        fi
    done

    # Step 5: 收集结果
    local messages
    messages=$(api_call "$url" "GET" "/session/$session_id/messages" "")

    local report_file="$REPORTS_DIR/${machine}-${session_id}-report.md"
    echo "# 任务报告" > "$report_file"
    echo "" >> "$report_file"
    echo "| 项目 | 值 |" >> "$report_file"
    echo "|------|-----|" >> "$report_file"
    echo "| 机器 | $machine |" >> "$report_file"
    echo "| Session | \`$session_id\` |" >> "$report_file"
    echo "| 任务 | $title |" >> "$report_file"
    echo "| 耗时 | ${elapsed}s |" >> "$report_file"
    echo "" >> "$report_file"
    echo "## 全部消息" >> "$report_file"
    echo "" >> "$report_file"
    echo '```json' >> "$report_file"
    echo "$messages" | jq '.' >> "$report_file"
    echo '```' >> "$report_file"

    echo ""
    echo "📄 报告: $report_file"
    echo "📎 Session: $session_id"

    # 记录到日志
    echo "[$(date -Iseconds)] $machine $session_id $title (${elapsed}s)" >> "$LOGS_DIR/dispatch.log"
}

cmd_push_all() {
    local label="$1" task_file="$2"
    local machines
    mapfile -t machines < <(get_machines_by_label "$label")

    if [ ${#machines[@]} -eq 0 ]; then
        echo "❌ 没有标签为 '$label' 的机器"
        exit 1
    fi

    echo "📡 批量分发到 ${#machines[@]} 台机器 (label=$label)"
    for m in "${machines[@]}"; do
        echo ""
        echo "━━━ $m ━━━"
        cmd_push "$m" "$task_file" || echo "   ⚠️ $m 执行失败，继续下一台..."
    done
}

cmd_status() {
    local machine="$1"
    MACHINE_CONFIG=$(get_machine "$machine")
    local url
    url=$(echo "$MACHINE_CONFIG" | jq -r '.url')

    local status_resp
    status_resp=$(api_call "$url" "GET" "/session/status" "")

    # 获取 session 列表
    local sessions
    sessions=$(api_call "$url" "GET" "/session" "")

    echo "📊 $machine Session 状态:"
    echo ""

    # 合并显示
    echo "$status_resp" | jq -r '.sessions // {} | to_entries[] | "\(.key): \(.value.type)"' 2>/dev/null || echo "(无活跃 session)"

    echo ""
    echo "--- 详细 ---"
    echo "$sessions" | jq -r '.[] | "  \(.id)  status=\(.status // "?")  agent=\(.agent // "?")  updated=\(.updated // "?")"' 2>/dev/null || echo "(无)"
}

cmd_report() {
    local machine="$1" session_id="$2"
    MACHINE_CONFIG=$(get_machine "$machine")
    local url
    url=$(echo "$MACHINE_CONFIG" | jq -r '.url')

    local messages
    messages=$(api_call "$url" "GET" "/session/$session_id/messages" "")

    local report_file="$REPORTS_DIR/${machine}-${session_id}-report.md"
    echo "$messages" | jq '.' > "$report_file"
    echo "📄 已保存: $report_file"

    # 提取纯文本输出到控制台
    echo "━━━ 任务输出 ━━━"
    echo "$messages" | jq -r '.[].parts[]? | select(.type=="text") | .text' 2>/dev/null | head -100
}

cmd_health() {
    echo "🩺 机器健康检查"
    echo ""

    jq -r 'keys[]' "$MACHINES_FILE" | while read -r m; do
        local cfg url
        cfg=$(get_machine "$m")
        url=$(echo "$cfg" | jq -r '.url')

        local health status_str
        health=$(curl -s --max-time 5 "$url/global/health" 2>/dev/null || echo '{"healthy":false}')
        if [ "$(echo "$health" | jq -r '.healthy // false')" = "true" ]; then
            status_str="✅ 在线"
        else
            status_str="❌ 不可达"
        fi
        printf "  %-20s %s (%s)\n" "$m" "$status_str" "$url"
    done
}

cmd_list_machines() {
    echo "📋 已注册机器:"
    jq -r 'to_entries[] | "  \(.key) → \(.value.url) [\(.value.labels // [] | join(","))]"' "$MACHINES_FILE"
}

cmd_abort() {
    local machine="$1" session_id="$2"
    MACHINE_CONFIG=$(get_machine "$machine")
    local url
    url=$(echo "$MACHINE_CONFIG" | jq -r '.url')

    api_call "$url" "POST" "/session/$session_id/abort" ""
    echo "🛑 已发送中断信号: $machine / $session_id"
}

# —— 入口 ——
init

COMMAND="${1:-}"
case "$COMMAND" in
    push)
        cmd_push "${2:?用法: $0 push <machine> <task.md>}" "${3:?}"
        ;;
    push-all)
        cmd_push_all "${2:?用法: $0 push-all <label> <task.md>}" "${3:?}"
        ;;
    status)
        cmd_status "${2:?用法: $0 status <machine>}"
        ;;
    report)
        cmd_report "${2:?用法: $0 report <machine> <session-id>}" "${3:?}"
        ;;
    health)
        cmd_health
        ;;
    list-machines)
        cmd_list_machines
        ;;
    abort)
        cmd_abort "${2:?}" "${3:?}"
        ;;
    *)
        echo "用法: $0 <command> [args...]"
        echo ""
        echo "命令:"
        echo "  push <machine> <task.md>      分发单个任务"
        echo "  push-all <label> <task.md>    按标签群发"
        echo "  status <machine>              查看机器 session 状态"
        echo "  report <machine> <session>    拉取任务报告"
        echo "  health                        健康检查"
        echo "  list-machines                 列出机器"
        echo "  abort <machine> <session>     中断任务"
        exit 1
        ;;
esac
