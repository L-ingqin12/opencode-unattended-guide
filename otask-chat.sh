#!/bin/bash
# ==================================================================
# otask-chat.sh — opencode run 多轮对话 + 结果检测
#
# 解决两个核心问题:
#   1. 如何用 opencode run 构建可控的多轮对话链
#   2. 每轮如何自动判定是否生成了有效结果
#
# 用法:
#   otask-chat.sh chain <prompts-file>           预编排链式执行
#   otask-chat.sh interactive "初始任务"          人工介入的多轮对话
#   otask-chat.sh auto "任务目标" [--max 10]      自动化到底
#
# 示例:
#   otask-chat.sh chain my-prompts.txt
#   otask-chat.sh interactive "分析错误日志"
#   otask-chat.sh auto "全面审计代码安全" --max 5
# ==================================================================

set -euo pipefail

# ── 配置 ──────────────────────────────────
MAX_TURNS=10
TIMEOUT=600
CONVERSATION_DIR="${OTASK_CONV_DIR:-./conversation-$(date +%Y%m%d-%H%M%S)}"
STATE_FILE=""

cmd="${1:-}"; shift 2>/dev/null || true

# ── 初始化会话目录 ────────────────────────
init_session() {
    mkdir -p "$CONVERSATION_DIR/turns"
    STATE_FILE="$CONVERSATION_DIR/state.json"
    echo '{"session_id":"","turn":0,"state":"STARTING","chain":[]}' > "$STATE_FILE"
    echo "📁 会话目录: $CONVERSATION_DIR"
}

# ── 更新状态文件 ──────────────────────────
update_state() {
    local sid="$1" turn="$2" state="$3" prompt="$4" result_file="$5" exit_code="$6"
    local text_chars tool_count duration
    text_chars=$(grep -c '"type":"text"' "$result_file" 2>/dev/null || echo 0)
    tool_count=$(grep -c '"type":"tool_use"' "$result_file" 2>/dev/null || echo 0)
    duration=""

    jq -n \
        --arg sid "$sid" \
        --argjson turn "$turn" \
        --arg state "$state" \
        --arg prompt "$prompt" \
        --arg result "$result_file" \
        --argjson text_chars "$text_chars" \
        --argjson tools "$tool_count" \
        --argjson exit "$exit_code" \
        '{
            session_id: $sid, turn: $turn, state: $state,
            last_prompt: $prompt, last_result: $result,
            text_lines: $text_chars, tool_count: $tools, exit_code: $exit
        }' > "$STATE_FILE"
}

# ── 执行一轮 ──────────────────────────────
run_turn() {
    local sid="$1" prompt="$2" turn="$3"
    local result_file="$CONVERSATION_DIR/turns/turn-${turn}.ndjson"
    local exit_code

    echo ""
    echo "── 第 $turn 轮 ──────────────────────────────"
    echo "   prompt: ${prompt:0:100}..."

    if [ -z "$sid" ]; then
        # 第一轮：新建 session
        set +e
        opencode run --format json "$prompt" \
            2>"$CONVERSATION_DIR/stderr.log" \
            > "$result_file"
        exit_code=$?
        set -e
        sid=$(head -1 "$result_file" 2>/dev/null | jq -r '.sessionID // empty')
    else
        # 后续轮：接续已有 session
        set +e
        opencode run --format json --session "$sid" "$prompt" \
            2>>"$CONVERSATION_DIR/stderr.log" \
            > "$result_file"
        exit_code=$?
        set -e
    fi

    echo "   退出码: $exit_code"
    echo "$sid" "$exit_code"
}

# ── 检测本轮结果 ──────────────────────────
detect_result() {
    local result_file="$1" exit_code="$2"
    local state="COMPLETED"

    # 错误: 退出码非零 + 无 NDJSON 产出
    if [ "$exit_code" -ne 0 ] && [ ! -s "$result_file" ]; then
        echo "ERROR"
        return
    fi

    # 空文件
    if [ ! -s "$result_file" ]; then
        echo "EMPTY"
        return
    fi

    # 流中有 error 事件
    local error_count
    error_count=$(grep -c '"type":"error"' "$result_file" 2>/dev/null || echo 0)
    if [ "$error_count" -gt 0 ]; then
        echo "ERROR"
        return
    fi

    # 有文本产出吗
    local text_count
    text_count=$(grep -c '"type":"text"' "$result_file" 2>/dev/null || echo 0)

    # agent 提问检测：最后一条 text 是否是问题
    local last_text is_question
    last_text=$(grep '"type":"text"' "$result_file" 2>/dev/null | tail -1 | jq -r '.content // .text // ""' 2>/dev/null)
    is_question=$(echo "$last_text" | grep -ciE '\?\s*$|吗？|？|确认|需要.*信息|请提供|哪个|选择|是否|要不要' 2>/dev/null || echo 0)

    if [ "$text_count" -eq 0 ]; then
        echo "EMPTY"
    elif [ "$is_question" -gt 0 ]; then
        echo "NEEDS_INPUT"
    else
        echo "COMPLETED"
    fi
}

# ── 终态检测：对话是否自然结束 ────────────
is_terminal() {
    local result_file="$1"
    local all_text
    all_text=$(grep '"type":"text"' "$result_file" 2>/dev/null | jq -r '.content // .text // ""' | tr '\n' ' ')
    echo "$all_text" | grep -qiE '完成|完毕|总结|以上|报告.*生成|已写入|分析.*完成|修复.*完成|done|complete|finish' 2>/dev/null
}

# ── 打印本轮摘要 ──────────────────────────
print_summary() {
    local state="$1" result_file="$2"
    local text_lines tool_lines
    text_lines=$(grep -c '"type":"text"' "$result_file" 2>/dev/null || echo 0)
    tool_lines=$(grep -c '"type":"tool_use"' "$result_file" 2>/dev/null || echo 0)

    case "$state" in
        COMPLETED)
            echo "   ✅ 完成 — text:${text_lines} 工具:${tool_lines}"
            ;;
        EMPTY)
            echo "   ⚠️  空输出 — 无文本产出 (工具:${tool_lines})"
            ;;
        ERROR)
            echo "   ❌ 错误"
            grep '"type":"error"' "$result_file" 2>/dev/null | tail -3 | jq -r '"      \(.message // .error)"' 2>/dev/null || true
            ;;
        NEEDS_INPUT)
            echo "   🤔 需要确认"
            ;;
    esac
}

# ═══════════════════════════════════════════════
#  模式 A: 预编排链
# ═══════════════════════════════════════════════
cmd_chain() {
    local prompts_file="${1:?用法: otask-chat.sh chain <prompts-file>}"
    [ -f "$prompts_file" ] || { echo "❌ 文件不存在: $prompts_file"; exit 1; }

    init_session
    local sid="" turn=0

    while IFS= read -r prompt; do
        [ -z "$prompt" ] && continue
        [[ "$prompt" =~ ^# ]] && continue  # 跳过注释行

        turn=$((turn + 1))
        if [ "$turn" -gt "$MAX_TURNS" ]; then
            echo "⚠️  达到最大轮次 $MAX_TURNS，停止"; break
        fi

        # 执行
        local exit_code
        read -r sid exit_code < <(run_turn "$sid" "$prompt" "$turn")
        local result_file="$CONVERSATION_DIR/turns/turn-${turn}.ndjson"

        # 检测
        local state
        state=$(detect_result "$result_file" "$exit_code")
        print_summary "$state" "$result_file"
        update_state "$sid" "$turn" "$state" "$prompt" "$result_file" "$exit_code"

        # 错误停止
        if [ "$state" = "ERROR" ]; then
            echo "❌ 链中断于第 $turn 轮"
            exit 1
        fi
    done < "$prompts_file"

    echo ""
    echo "═══════════════════════════════════════"
    echo "  链完成 ($turn 轮)"
    echo "  Session: $sid"
    echo "  结果目录: $CONVERSATION_DIR"
    echo "═══════════════════════════════════════"
}

# ═══════════════════════════════════════════════
#  模式 B: 交互式
# ═══════════════════════════════════════════════
cmd_interactive() {
    local first_prompt="${1:?用法: otask-chat.sh interactive \"初始任务\"}"
    init_session
    local sid="" turn=0

    # 第一轮
    turn=1
    local exit_code
    read -r sid exit_code < <(run_turn "" "$first_prompt" "$turn")
    local result_file="$CONVERSATION_DIR/turns/turn-${turn}.ndjson"
    local state
    state=$(detect_result "$result_file" "$exit_code")
    print_summary "$state" "$result_file"
    update_state "$sid" "$turn" "$state" "$first_prompt" "$result_file" "$exit_code"

    # 显示输出
    echo ""
    echo "── agent 输出 ──"
    grep '"type":"text"' "$result_file" 2>/dev/null | jq -r '.content // .text // ""' | head -50

    # 交互循环
    while true; do
        echo ""
        if [ "$state" = "NEEDS_INPUT" ]; then
            echo -n "agent 需要更多信息，请输入 (空=结束): "
        else
            echo -n "下一轮 prompt (空=结束 / .=自动总结): "
        fi

        read -r next
        [ -z "$next" ] && break

        # "." = 让 agent 自己做最终总结
        if [ "$next" = "." ]; then
            next="请根据以上所有分析，生成最终的完整总结报告"
        fi

        turn=$((turn + 1))
        if [ "$turn" -gt "$MAX_TURNS" ]; then
            echo "⚠️  达到最大轮次 $MAX_TURNS"; break
        fi

        read -r sid exit_code < <(run_turn "$sid" "$next" "$turn")
        result_file="$CONVERSATION_DIR/turns/turn-${turn}.ndjson"
        state=$(detect_result "$result_file" "$exit_code")
        print_summary "$state" "$result_file"
        update_state "$sid" "$turn" "$state" "$next" "$result_file" "$exit_code"

        # 显示输出
        echo "── agent 输出 ──"
        grep '"type":"text"' "$result_file" 2>/dev/null | jq -r '.content // .text // ""' | head -50

        # 自然结束
        if [ "$state" = "COMPLETED" ] && is_terminal "$result_file"; then
            echo ""
            echo "✅ agent 已完成任务（检测到总结性输出）"
            break
        fi
    done

    echo ""
    echo "Session: $sid (共 $turn 轮)"
    echo "结果目录: $CONVERSATION_DIR"
}

# ═══════════════════════════════════════════════
#  模式 C: 自动到底
# ═══════════════════════════════════════════════
cmd_auto() {
    local goal="${1:?用法: otask-chat.sh auto \"任务目标\" [--max N]}"
    shift

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max) MAX_TURNS="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_session
    local sid="" turn=0 state="STARTING"

    # 第一轮：布置任务
    turn=1
    local exit_code
    read -r sid exit_code < <(run_turn "" "$goal" "$turn")
    local result_file="$CONVERSATION_DIR/turns/turn-${turn}.ndjson"
    state=$(detect_result "$result_file" "$exit_code")
    print_summary "$state" "$result_file"
    update_state "$sid" "$turn" "$state" "$goal" "$result_file" "$exit_code"

    # 自动循环
    local consecutive_empty=0
    while [ "$turn" -lt "$MAX_TURNS" ]; do
        local next_prompt=""

        case "$state" in
            COMPLETED)
                if is_terminal "$result_file"; then
                    echo ""
                    echo "✅ 任务自然完成"
                    break
                fi
                next_prompt="继续完成上述任务。给出具体结果，不要只描述过程。"
                ;;
            EMPTY)
                consecutive_empty=$((consecutive_empty + 1))
                if [ "$consecutive_empty" -ge 2 ]; then
                    echo ""
                    echo "⚠️  连续 ${consecutive_empty} 轮无文本产出，可能已完成或无法继续"
                    break
                fi
                next_prompt="请用文字总结你的发现和已完成的操作。"
                ;;
            NEEDS_INPUT)
                next_prompt="请自行做出合理假设并继续，不需要等我确认。"
                ;;
            ERROR)
                next_prompt="上次出错了。请换一种方式继续完成任务。"
                consecutive_empty=0
                ;;
        esac

        # 重置空轮计数
        [ "$state" != "EMPTY" ] && consecutive_empty=0

        turn=$((turn + 1))
        read -r sid exit_code < <(run_turn "$sid" "$next_prompt" "$turn")
        result_file="$CONVERSATION_DIR/turns/turn-${turn}.ndjson"
        state=$(detect_result "$result_file" "$exit_code")
        print_summary "$state" "$result_file"
        update_state "$sid" "$turn" "$state" "$next_prompt" "$result_file" "$exit_code"
    done

    # 最终输出
    echo ""
    echo "═══════════════════════════════════════"
    echo "  自动化完成 ($turn 轮)"
    echo "  最终状态: $state"
    echo "  Session: $sid"
    echo "═══════════════════════════════════════"

    # 提取最后一轮的有效输出
    if [ "$state" = "COMPLETED" ] || [ "$state" = "EMPTY" ]; then
        echo ""
        echo "── 最终输出 ──"
        grep '"type":"text"' "$result_file" 2>/dev/null | jq -r '.content // .text // ""' | tail -100
    fi

    echo ""
    echo "完整 event log: $CONVERSATION_DIR/turns/"
}

# ── 入口 ──────────────────────────────────
case "$cmd" in
    chain)
        cmd_chain "$@"
        ;;
    interactive)
        cmd_interactive "$@"
        ;;
    auto)
        cmd_auto "$@"
        ;;
    *)
        echo "otask-chat — opencode run 多轮对话 + 结果检测" >&2
        echo "" >&2
        echo "用法:" >&2
        echo "  otask-chat.sh chain <prompts-file>           预编排链 (每行一个 prompt)" >&2
        echo "  otask-chat.sh interactive \"第一轮任务\"       交互式多轮" >&2
        echo "  otask-chat.sh auto \"任务目标\" [--max 10]    自动到底" >&2
        echo "" >&2
        echo "结果状态:" >&2
        echo "  COMPLETED   = 有文本产出，正常完成" >&2
        echo "  EMPTY       = 无文本产出（只有工具操作）" >&2
        echo "  ERROR       = 执行出错" >&2
        echo "  NEEDS_INPUT = agent 在等回复" >&2
        echo "" >&2
        echo "prompts.txt 示例:" >&2
        echo "  # 注释行会被跳过" >&2
        echo "  分析 /var/log/app/error.log 的错误类型" >&2
        echo "  针对 TOP 3 错误分析根因" >&2
        echo "  生成修复方案并写入 fix-plan.md" >&2
        exit 1
        ;;
esac
