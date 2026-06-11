#!/bin/bash
# ============================================================
# heartbeat.sh — OpenCode 任务心跳监控
#
# 用法:
#   heartbeat.sh <events.ndjson> [超时秒数] [--notify webhook_url]
#
# 工作原理:
#   tail -f 跟踪 NDJSON 事件流，检测心跳信号。
#   - 每收到事件 → 重置超时计时器
#   - 流关闭 → 判定任务完成，收集最终报告
#   - 超时无事件 → 告警，可选中断任务
#
# 示例:
#   opencode run --format json "task" 2>/tmp/stderr.log | tee /tmp/events.ndjson &
#   ./heartbeat.sh /tmp/events.ndjson 300
# ============================================================

set -euo pipefail

# —— 配置 ——
EVENTS_FILE="${1:?用法: $0 <events.ndjson> [timeout_seconds] [--notify url]}"
TIMEOUT="${2:-300}"           # 默认 300s 无事件判定挂起
NOTIFY_URL=""
if [[ "${3:-}" == "--notify" ]]; then
    NOTIFY_URL="${4:-}"
fi

STATE_FILE="/tmp/oc-heartbeat-$(basename "$EVENTS_FILE" .ndjson).state"
REPORT_FILE="/tmp/oc-heartbeat-$(basename "$EVENTS_FILE" .ndjson).report.md"

# —— 状态初始化 ——
SESSION_ID=""
LAST_EVENT_TIME=$(date +%s)
STEP_CURRENT=0
STEP_TOTAL=0
TOOL_COUNT=0
ERROR_COUNT=0
FINAL_TEXT=""
STATUS="running"

echo "{\"status\":\"$STATUS\",\"started_at\":\"$(date -Iseconds)\"}" > "$STATE_FILE"

# —— 信号处理 ——
cleanup() {
    echo "🧹 清理中..."
    echo "{\"status\":\"stopped\",\"stopped_at\":\"$(date -Iseconds)\"}" > "$STATE_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

# —— 通知函数 ——
notify() {
    local level="$1" msg="$2"
    echo "[$(date '+%H:%M:%S')] [$level] $msg"
    if [ -n "$NOTIFY_URL" ]; then
        curl -s -X POST "$NOTIFY_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"level\":\"$level\",\"message\":\"$msg\",\"session\":\"$SESSION_ID\"}" \
            > /dev/null 2>&1 || true
    fi
}

# —— 提取最终报告 ——
extract_report() {
    echo "# OpenCode 任务报告" > "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "| 项目 | 值 |" >> "$REPORT_FILE"
    echo "|------|-----|" >> "$REPORT_FILE"
    echo "| Session ID | \`$SESSION_ID\` |" >> "$REPORT_FILE"
    echo "| 状态 | $STATUS |" >> "$REPORT_FILE"
    echo "| 步骤数 | $STEP_CURRENT |" >> "$REPORT_FILE"
    echo "| 工具调用 | $TOOL_COUNT |" >> "$REPORT_FILE"
    echo "| 错误数 | $ERROR_COUNT |" >> "$REPORT_FILE"
    echo "| 完成时间 | $(date -Iseconds) |" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "## 输出摘要" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # 收集所有 text 类型事件中的最终回复（最后 500 行中的 text 事件）
    local text_content
    text_content=$(grep '"type":"text"' "$EVENTS_FILE" 2>/dev/null | tail -20 | jq -r '.content // .text // empty' 2>/dev/null | head -100)
    if [ -n "$text_content" ]; then
        echo "$text_content" >> "$REPORT_FILE"
    else
        # fallback: 拿最后 500 行中的 text/delta
        grep '"type":"text"\|"type":"delta"' "$EVENTS_FILE" 2>/dev/null | tail -30 | jq -r '.content // .delta // .text // empty' 2>/dev/null >> "$REPORT_FILE" || echo "(无文本输出)" >> "$REPORT_FILE"
    fi

    echo "" >> "$REPORT_FILE"
    echo "## 工具调用摘要" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    grep '"type":"tool_use"' "$EVENTS_FILE" 2>/dev/null | jq -r '"| `\(.tool // .name)` | \(.input // {} | tostring | .[0:80]) |"' 2>/dev/null >> "$REPORT_FILE" || echo "| (无) | |" >> "$REPORT_FILE"

    notify "info" "报告已生成: $REPORT_FILE"
}

# —— 心跳监控主循环 ——
echo "🫀 心跳监控启动 (超时: ${TIMEOUT}s, 文件: $EVENTS_FILE)"

# 等待文件出现
while [ ! -f "$EVENTS_FILE" ]; do
    sleep 0.5
done

# tail -f 方式实时追踪（兼容管道写入）
# 因为 tee 写入可能有缓冲，用 polling fallback
POLL_INTERVAL=1
LAST_SIZE=0

while true; do
    CURRENT_SIZE=$(stat -c%s "$EVENTS_FILE" 2>/dev/null || echo 0)

    if [ "$CURRENT_SIZE" -gt "$LAST_SIZE" ]; then
        # 有新数据，读取增量
        NEW_DATA=$(dd if="$EVENTS_FILE" bs=1 skip="$LAST_SIZE" count=$((CURRENT_SIZE - LAST_SIZE)) 2>/dev/null)

        # 逐行解析新事件
        while IFS= read -r line; do
            [ -z "$line" ] && continue

            EVENT_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
            [ -z "$EVENT_TYPE" ] && continue

            # 首次获取 session_id
            if [ -z "$SESSION_ID" ]; then
                SESSION_ID=$(echo "$line" | jq -r '.sessionID // empty' 2>/dev/null)
                if [ -n "$SESSION_ID" ]; then
                    notify "info" "Session: $SESSION_ID"
                fi
            fi

            # 更新最后事件时间
            LAST_EVENT_TIME=$(date +%s)

            # 事件分类处理
            case "$EVENT_TYPE" in
                step_start)
                    STEP_CURRENT=$(echo "$line" | jq -r '.step // 0' 2>/dev/null)
                    notify "info" "📋 Step $STEP_CURRENT 开始"
                    ;;
                step_finish)
                    notify "info" "✅ Step $STEP_CURRENT 完成"
                    ;;
                tool_use)
                    TOOL_NAME=$(echo "$line" | jq -r '.tool // .name // "unknown"' 2>/dev/null)
                    TOOL_COUNT=$((TOOL_COUNT + 1))
                    echo "   🔧 #$TOOL_COUNT: $TOOL_NAME"
                    ;;
                error)
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    ERROR_MSG=$(echo "$line" | jq -r '.message // .error // "unknown error"' 2>/dev/null)
                    notify "error" "❌ 错误: $ERROR_MSG"
                    ;;
                text)
                    # 只打进度点，不全量输出
                    TEXT_PREVIEW=$(echo "$line" | jq -r '.content // .text // ""' 2>/dev/null | head -c 80)
                    [ -n "$TEXT_PREVIEW" ] && echo "   💬 ${TEXT_PREVIEW}..."
                    ;;
            esac
        done <<< "$NEW_DATA"

        LAST_SIZE=$CURRENT_SIZE
    fi

    # 检查超时
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_EVENT_TIME))

    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
        notify "error" "⏰ 超时! ${ELAPSED}s 无事件 (阈值: ${TIMEOUT}s)"
        STATUS="timeout"

        # 尝试从 serve API 检查状态（如果同一台机）
        if [ -n "$SESSION_ID" ] && curl -s "http://localhost:4096/session/status" > /dev/null 2>&1; then
            SESSION_STATUS=$(curl -s "http://localhost:4096/session/status" | jq -r ".sessions.\"$SESSION_ID\".type // \"unknown\"")
            if [ "$SESSION_STATUS" = "idle" ]; then
                notify "info" "实际状态为 idle，任务可能已完成，报告生成中..."
                STATUS="completed"
                extract_report
                break
            fi
        fi

        # 确认挂起
        extract_report
        exit 3
    fi

    # 检查流是否结束（文件不再增长 + 进程已退出）
    if [ -n "${OC_PID:-}" ] && ! kill -0 "$OC_PID" 2>/dev/null; then
        # opencode 进程已退出
        sleep 2  # 等最后的事件 flush
        if [ "$(stat -c%s "$EVENTS_FILE" 2>/dev/null || echo 0)" -eq "$CURRENT_SIZE" ]; then
            STATUS="completed"
            EXIT_CODE=$(wait "$OC_PID" 2>/dev/null; echo $?)
            notify "info" "✅ 任务完成 (exit=$EXIT_CODE)"
            extract_report
            exit 0
        fi
    fi

    sleep "$POLL_INTERVAL"
done
