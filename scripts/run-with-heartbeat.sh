#!/bin/bash
# ============================================================
# run-with-heartbeat.sh — opencode run 包装器（带心跳监控）
#
# 用法:
#   ./run-with-heartbeat.sh "你的任务描述" [--timeout 600] [--notify webhook_url]
#
# 功能:
#   1. 使用 --format json 执行 opencode run（正确输出 session_id）
#   2. 后台 heartbeat.sh 监控任务进度
#   3. 任务完成自动生成报告
#   4. 超时自动中断
#
# 输出:
#   stdout: 最终报告路径和 session_id
#   文件:   /tmp/oc-run-<timestamp>/ 下有 events.ndjson, report.md, exit_code
# ============================================================

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="/tmp/oc-run-$TIMESTAMP"
mkdir -p "$RUN_DIR"

PROMPT="${1:?用法: $0 \"任务描述\" [--timeout 秒] [--notify url] [--agent auto] [--model provider/model]}"
shift

TIMEOUT=600
NOTIFY_URL=""
AGENT=""
MODEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --notify)  NOTIFY_URL="$2"; shift 2 ;;
        --agent)   AGENT="--agent $2"; shift 2 ;;
        --model)   MODEL="--model $2"; shift 2 ;;
        *)         echo "未知参数: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEARTBEAT_SH="$SCRIPT_DIR/heartbeat.sh"

echo "════════════════════════════════════════"
echo "  OpenCode Run + Heartbeat"
echo "════════════════════════════════════════"
echo "  执行目录: $RUN_DIR"
echo "  超时:     ${TIMEOUT}s"
echo "  Agent:    ${AGENT:-默认}"
echo "  Model:    ${MODEL:-默认}"
echo ""

# —— 启动 opencode run ——
echo "▶️  启动 opencode run --format json..."

# 使用 --format json（非 --json）以获取完整的 NDJSON 事件流
opencode run --format json $AGENT $MODEL "$PROMPT" \
    2>"$RUN_DIR/stderr.log" \
    | tee "$RUN_DIR/events.ndjson" &
OC_PID=$!

echo "   PID: $OC_PID"

# —— 后台启动心跳监控 ——
HEARTBEAT_PID=""
if [ -x "$HEARTBEAT_SH" ]; then
    if [ -n "$NOTIFY_URL" ]; then
        "$HEARTBEAT_SH" "$RUN_DIR/events.ndjson" "$TIMEOUT" --notify "$NOTIFY_URL" &
    else
        "$HEARTBEAT_SH" "$RUN_DIR/events.ndjson" "$TIMEOUT" &
    fi
    HEARTBEAT_PID=$!
    echo "   🫀 心跳监控 PID: $HEARTBEAT_PID"
else
    echo "   ⚠️  heartbeat.sh 不可用，使用简单等待模式"
fi

# —— 等待 opencode 完成 ——
echo ""
echo "⏳ 等待任务完成..."
wait "$OC_PID" 2>/dev/null || true
OC_EXIT=$?
echo "$OC_EXIT" > "$RUN_DIR/exit_code"

# 等待心跳监控收尾
if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    sleep 2
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
fi

# —— 提取 session_id ——
SESSION_ID=""
if [ -f "$RUN_DIR/events.ndjson" ]; then
    SESSION_ID=$(head -1 "$RUN_DIR/events.ndjson" | jq -r '.sessionID // empty' 2>/dev/null)
fi

# —— 输出结果 ——
echo ""
echo "════════════════════════════════════════"
echo "  ✅ 任务执行完毕"
echo "════════════════════════════════════════"
echo "  Session:  $SESSION_ID"
echo "  退出码:   $OC_EXIT"
echo "  事件数:   $(wc -l < "$RUN_DIR/events.ndjson" 2>/dev/null || echo 0)"
echo "  事件文件: $RUN_DIR/events.ndjson"
echo "  错误日志: $RUN_DIR/stderr.log"

# 报告文件
REPORT_FILE="$RUN_DIR/report.md"
if [ -f "/tmp/oc-heartbeat-events.report.md" ]; then
    cp "/tmp/oc-heartbeat-events.report.md" "$REPORT_FILE"
    echo "  报告文件: $REPORT_FILE"
fi

# 输出 JSON 摘要（方便脚本解析）
jq -n \
    --arg session_id "$SESSION_ID" \
    --arg exit_code "$OC_EXIT" \
    --arg run_dir "$RUN_DIR" \
    --arg report "$REPORT_FILE" \
    '{
        session_id: $session_id,
        exit_code: $exit_code,
        run_dir: $run_dir,
        report: $report
    }'

echo ""
echo "📎 后续操作:"
echo "  查看事件: cat $RUN_DIR/events.ndjson | jq"
echo "  继续对话: opencode run --format json --session $SESSION_ID \"下一步任务\""
