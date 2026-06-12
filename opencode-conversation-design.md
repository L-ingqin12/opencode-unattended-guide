# OpenCode 多轮对话 + 结果检测 — 完整策略

> 如何用 `opencode run --format json` 构建可控的多轮对话链，并在每轮自动判定是否生成了有效结果。

---

## 1. 核心状态机

每一轮 `opencode run` 执行后，根据 NDJSON 事件流判定进入哪个状态：

```
                    ┌─────────────┐
           ┌───────▶│  RUNNING    │◀──────┐
           │        └──────┬──────┘       │
           │               │              │
    [事件到达]         [流关闭]        [超时]
           │               │              │
           │        ┌──────┴──────┐       │
           │        │   检测终态   │       │
           │        └──┬──┬──┬──┬─┘       │
           │           │  │  │  │         │
           │     ┌─────┘  │  │  └─────┐   │
           │     ▼        ▼  ▼        ▼   │
           │  COMPLETED  EMPTY ERROR TIMEOUT
           │     │        │    │      │    │
           │     │        │    │      │    │
           └─────┼────────┴────┴──────┘────┘
                 │         [重试/放弃]
                 ▼
            [继续下一轮 or 结束]
```

### 五态定义

| 状态 | 判定条件 | 含义 |
|------|----------|------|
| **COMPLETED** | 流正常关闭 + 有 text 类型事件产出 | 任务完成，产出了文本结论 |
| **EMPTY** | 流正常关闭 + 无 text 事件（只有 tool_use/tool_result） | agent 只做了操作，没有文字总结 |
| **ERROR** | NDJSON 中出现 `"type":"error"` 事件或 exit_code ≠ 0 | 执行出错 |
| **TIMEOUT** | N 秒无新事件到达 | 疑似挂起 |
| **NEEDS_INPUT** | 最后一轮 text 是提问句式（需额外启发式检测） | agent 需要补充信息 |

---

## 2. 结果检测：每轮如何判定

### 2.1 从 NDJSON 流提取信号

```bash
# 流关闭 = 任务完成
# 在 opencode 进程退出后，检查最终状态

# 信号 1: 是否有文本产出
HAS_TEXT=$(grep -c '"type":"text"' events.ndjson)

# 信号 2: 是否有错误
HAS_ERROR=$(grep -c '"type":"error"' events.ndjson)

# 信号 3: 工具调用次数（粗略判断工作量）
TOOL_COUNT=$(grep -c '"type":"tool_use"' events.ndjson)

# 信号 4: 最后一条 text 是否是提问（agent 需要更多信息）
LAST_TEXT=$(grep '"type":"text"' events.ndjson | tail -1 | jq -r '.content // .text // ""')
IS_QUESTION=$(echo "$LAST_TEXT" | grep -cE '\?\s*$|吗？|？|确认|需要.*信息|请提供|哪个|选择')

# 信号 5: 进程退出码
EXIT_CODE=$?
```

### 2.2 判定逻辑

```
if EXIT_CODE ≠ 0 or HAS_ERROR > 0  →  ERROR
elif 流未关闭 + 超时                 →  TIMEOUT
elif HAS_TEXT == 0                  →  EMPTY (只有工具操作，无总结)
elif IS_QUESTION                    →  NEEDS_INPUT (agent 在等回答)
else                                →  COMPLETED
```

### 2.3 `--on-complete` 钩子辅助

```bash
opencode run --format json "task" \
  --on-complete 'echo "EXIT=$EXIT_CODE DURATION=$DURATION_MS MSGS=$MESSAGE_COUNT" >> /tmp/turn-result.env'
```

此后可以从 `/tmp/turn-result.env` 快速读取退出码和耗时，无需解析完整 NDJSON。

---

## 3. 多轮对话链：三种驱动模式

### 模式 A：预编排链（确定性的步骤序列）

```bash
# 预先定义好每一步的 prompt
PROMPTS=(
    "分析 /var/log/app/error.log 中的错误类型"
    "针对上一步 TOP 3 错误，逐一分析根因"
    "给出修复方案并排优先级"
    "将完整分析报告写入 report.md"
)

# 链式执行
SESSION_ID=""
for prompt in "${PROMPTS[@]}"; do
    if [ -z "$SESSION_ID" ]; then
        # 第一轮：新建
        output=$(opencode run --format json "$prompt" 2>/tmp/stderr | tee /tmp/turn.ndjson)
        SESSION_ID=$(head -1 /tmp/turn.ndjson | jq -r '.sessionID')
    else
        # 后续轮：接续
        output=$(opencode run --format json --session "$SESSION_ID" "$prompt" 2>/tmp/stderr | tee /tmp/turn.ndjson)
    fi

    # 检测结果
    state=$(detect_result /tmp/turn.ndjson)
    if [ "$state" = "ERROR" ] || [ "$state" = "TIMEOUT" ]; then
        echo "❌ 第 $step 步失败 ($state)，中止链"
        break
    fi
done
```

### 模式 B：交互式（人机协作）

```bash
# 人发起第一轮
opencode run --format json "初步分析" | tee turn-1.ndjson
SESSION_ID=$(head -1 turn-1.ndjson | jq -r '.sessionID')

# 人审阅结果后决定下一步
cat turn-1.ndjson | grep '"type":"text"' | jq -r '.content'

# 人输入下一轮 prompt
read -p "下一轮 (空=结束): " next_prompt
[ -z "$next_prompt" ] && exit

opencode run --format json --session "$SESSION_ID" "$next_prompt" | tee turn-2.ndjson
```

### 模式 C：条件链（根据结果动态决定下一步）

```bash
# 第一轮：分析
result=$(opencode run --format json --session "$SID" "分析错误日志")
state=$(detect_result)

case "$state" in
    COMPLETED)
        # 自动进入总结
        opencode run --format json --session "$SID" "根据分析结果，生成修复方案"
        ;;
    EMPTY)
        # 没有文本输出，让 agent 总结
        opencode run --format json --session "$SID" "请用文字总结你的发现"
        ;;
    NEEDS_INPUT)
        # 提取 agent 的问题，自动回答
        question=$(get_last_question)
        answer=$(lookup_answer "$question")  # 从知识库或默认值
        opencode run --format json --session "$SID" "$answer"
        ;;
    ERROR)
        # 重试一次
        opencode run --format json --session "$SID" "上次出错了，请重新尝试"
        ;;
esac
```

---

## 4. 终态判定：对话何时结束

### 自然终态

| 条件 | 说明 |
|------|------|
| 当前轮产出 COMPLETED + 文本以报告/总结语气结尾 | 任务自然完成 |
| 用户发送空 prompt（交互模式） | 显式结束 |
| 达到预设的最大轮次 | 防无限循环 |
| agent 连续 2 轮产出 EMPTY | agent 已无事可做 |

### 终态检测启发式

```bash
is_terminal() {
    local text="$1"

    # 包含这些模式 = agent 认为任务已完成
    echo "$text" | grep -qiE \
        '完成|完毕|以上是|总结|报告.*生成|已写入|分析结果|修复.*完成|done|complete|finished'
}
```

---

## 5. 异常恢复

### 5.1 超时恢复

```bash
# 超时后不丢弃 session，而是重试
if [ "$state" = "TIMEOUT" ]; then
    # 方案 A: 用更简单的 prompt 重试
    opencode run --format json --session "$SID" "请继续你未完成的任务，用最简洁的方式完成" &

    # 方案 B: 中断 session，新建一个接续（状态可能已污染）
    opencode run --format json --session "$SID" --fork "基于已有分析继续"
fi
```

### 5.2 错误恢复

```bash
if [ "$state" = "ERROR" ]; then
    # 提取错误信息
    error_msg=$(grep '"type":"error"' turn.ndjson | tail -1 | jq -r '.message')

    # 记录错误，重试（最多 3 次）
    retry_count=$((retry_count + 1))
    if [ $retry_count -le 3 ]; then
        opencode run --format json --session "$SID" \
            "上次任务遇到了错误: $error_msg。请换一种方式重新完成。"
    else
        echo "❌ 已重试 3 次，放弃"
    fi
fi
```

### 5.3 会话恢复

```bash
# 如果整个脚本崩溃，重新运行时恢复会话
if [ -f ".conversation-state" ]; then
    source .conversation-state   # SESSION_ID, TURN, STATE
    echo "📎 恢复 session $SESSION_ID (第 $TURN 轮)"
else
    # 新建会话
    ...
fi
```

---

## 6. 会话状态文件

每轮更新：

```json
{
  "session_id": "ses_xxx",
  "turn": 3,
  "state": "COMPLETED",
  "last_prompt": "分析错误日志",
  "last_result_file": "turns/turn-3.ndjson",
  "text_output_chars": 1247,
  "tool_count": 15,
  "duration_ms": 45200,
  "exit_code": 0,
  "chain": [
    {"turn": 1, "prompt": "...", "state": "COMPLETED"},
    {"turn": 2, "prompt": "...", "state": "COMPLETED"},
    {"turn": 3, "prompt": "...", "state": "COMPLETED"}
  ]
}
```

---

## 7. 实现：otask-chat.sh

见同级文件 `otask-chat.sh`，实现上述完整策略的三个模式：

```bash
# 模式 A: 预编排链
./otask-chat.sh chain prompts.txt

# 模式 B: 交互式
./otask-chat.sh interactive "初始分析任务"

# 模式 C: 条件链（自动进行到底）
./otask-chat.sh auto "你的完整任务目标" --max-turns 10
```

---

> 📅 2026-06-11
>
> 相关: [otask.sh](otask.sh) / [opencode-unattended-continuous-guide.md](opencode-unattended-continuous-guide.md)
