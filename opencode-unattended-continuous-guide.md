# OpenCode 无人值守与持续对话指南

> 如何使用 `opencode run` 实现零交互、不间断的任务执行与多轮持续对话

---

## 目录

- [1. 概述](#1-概述)
- [2. 快速上手：opencode run](#2-快速上手opencode-run)
- [3. 权限配置：消除所有交互中断](#3-权限配置消除所有交互中断)
- [4. 持续对话：Session 管理](#4-持续对话session-管理)
- [5. 进阶：ACP 协议编程式控制](#5-进阶acp-协议编程式控制)
- [6. CI/CD 与自动化集成](#6-cicd-与自动化集成)
- [7. 常见坑点与规避方案](#7-常见坑点与规避方案)
- [8. 参考资源](#8-参考资源)

---

## 1. 概述

OpenCode 是一个开源的终端 AI 编码助手。默认情况下它以 TUI 交互模式运行，每次执行敏感操作（写文件、执行命令、调用子 agent）都需要用户确认。对于脚本化、CI/CD、批量任务等无人值守场景，需要一套完整的配置方案来消除这些人工确认点，并实现任务链的持续对话。

### 无人值守的四个层次

| 层次 | 目标 | 手段 |
|------|------|------|
| **权限层** | 消除工具确认弹窗 | `opencode.json` 中 `"permission": "allow"` |
| **会话层** | 多轮对话不断开 | `--session <id>` / `--continue` / ACP |
| **调度层** | 按时间/事件触发 | cron / systemd timer / CI schedule / webhook |
| **通知层** | 结果触达用户 | `--on-complete` / webhook / PushNotification |

---

## 2. 快速上手：opencode run

### 基本命令

```bash
opencode run "你的任务描述"
```

这是 OpenCode 的非交互模式入口。Agent 完成单次任务后自动退出，适合脚本和 CI。

### 常用参数

| 参数 | 缩写 | 说明 |
|------|------|------|
| `--message` | | 任务指令文本 |
| `--agent` | `-a` | 指定 agent（如 `sisyphus`、自定义 agent） |
| `--model` | `-m` | 指定模型，格式 `provider/model` |
| `--session-id` | | 恢复指定会话（持续对话核心） |
| `--continue` | `-c` | 继续上一次会话 |
| `--json` | | 输出结构化 JSON（适合脚本解析） |
| `--on-complete` | | 任务完成后执行的 shell 命令 |
| `--verbose` | `-v` | 详细事件追踪 |
| `--file` | `-f` | 附加文件到 prompt（可多次使用） |
| `--attach` | | 连接到运行中的 OpenCode 服务器 |
| `--port` | `-p` | 指定服务器端口 |
| `--fork` | | 从已有 session 分叉新分支 |

### 环境变量

```bash
export OPENCODE_CLIENT=run              # 告诉工具注册表排除交互式工具
export OPENCODE_CLI_RUN_MODE=true       # 标记当前为非交互模式
export OPENCODE_DISABLE_AUTOUPDATE=true # 禁用自动更新检查（避免脚本中弹出升级提示）
export OPENCODE_DISABLE_WATCHER=true    # 禁用文件监听（减少资源消耗）
export OPENCODE_SERVER_PASSWORD=xxx     # 连接 server 时自动注入 Basic Auth
```

---

## 3. 权限配置：消除所有交互中断

> ⚠️ 这是无人值守能否跑通的**根本**。权限不对，agent 执行到一半就会挂起等待用户确认。

### 3.1 全局放行（最简单）

在项目的 `opencode.json` 中：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow"
}
```

### 3.2 精细控制（推荐生产环境）

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "*": "allow",
    "bash": "allow",
    "edit": "allow",
    "read": "allow",
    "glob": "allow",
    "grep": "allow",
    "list": "allow",
    "task": "allow",
    "webfetch": "allow",
    "websearch": "allow",
    "question": "allow",
    "plan_enter": "allow",
    "plan_exit": "allow",
    "doom_loop": "allow",
    "external_directory": "allow"
  }
}
```

> 🔑 **关键**：`question`、`plan_enter`、`plan_exit` 这三项在 session 初始化时可能被内置 preset 覆盖为 `"deny"`。如果配了全局 allow 后仍然中断，见 [7.1 节](#71-session-preset-覆盖权限)。

### 3.3 配置作用域（优先级从低到高）

| 优先级 | 位置 |
|--------|------|
| 1 (最低) | Remote config (`.well-known/opencode`) |
| 2 | Global (`~/.config/opencode/opencode.json`) |
| 3 | 自定义 (`OPENCODE_CONFIG` 环境变量) |
| 4 | Project (`opencode.json` 在项目根目录) |
| 5 | `.opencode/` 目录 |
| 6 (最高) | Inline config (`OPENCODE_CONFIG_CONTENT` 环境变量) |

### 3.4 自定义 Agent（无人值守专用）

```json
{
  "agent": {
    "auto": {
      "description": "全自动模式，所有操作无需确认",
      "mode": "primary",
      "permission": "allow"
    }
  }
}
```

使用：

```bash
opencode run --agent auto "你的任务"
```

---

## 4. 持续对话：Session 管理

每次 `opencode run` 的上下文会自动持久化。通过 session ID 可以在后续调用中恢复完整上下文，实现无间断的多轮对话。

### 4.1 基础用法

```bash
# 第一轮：启动任务
opencode run "分析 src/ 目录下的代码结构"

# 第二轮：接续上一轮（自动恢复上一轮的全部上下文）
opencode run --continue "根据上面的分析，重构 auth 模块"

# 第三轮：继续
opencode run --continue "给重构后的 auth 模块写单元测试"
```

### 4.2 显式管理 Session ID（更可靠）

`--continue` 只能接最后一次会话。管理多个并行对话链需要用 `--session`：

```bash
# 列出所有 sessions
opencode session list
# 输出示例：
# ses_561eca5ebffeCngoybZWxbTrD8  2026-06-11 10:23  12 msgs  /root/myproject
# ses_982dab7f1234XyZabcDEF456789  2026-06-11 09:15  5 msgs   /root/myproject

# 接续指定 session
opencode run --session ses_561eca5ebffeCngoybZWxbTrD8 "深入分析上一个问题"
```

### 4.3 自动化脚本：自管理 Session

```bash
#!/bin/bash
# 持续对话自动化脚本
set -euo pipefail

PROJECT_DIR="/root/myproject"
SESSION_FILE="$PROJECT_DIR/.opencode-sid"

get_or_continue() {
    local prompt="$1"

    if [ -f "$SESSION_FILE" ]; then
        SID=$(cat "$SESSION_FILE")
        echo "📎 接续: $SID"
        opencode run --session "$SID" "$prompt"
    else
        echo "🆕 新建 session"
        # 用 --json 输出获取 session id
        output=$(opencode run --json "$prompt" 2>&1)
        SID=$(echo "$output" | jq -r '.sessionId // empty')

        # fallback: 从 session list 获取最新
        if [ -z "$SID" ]; then
            SID=$(opencode session list -n 1 2>/dev/null | head -1 | awk '{print $1}')
        fi

        echo "$SID" > "$SESSION_FILE"
        echo "   Session: $SID"
    fi
}

# 使用
get_or_continue "分析项目代码结构，输出所有模块职责"
get_or_continue "找出架构层面的3个主要问题"
get_or_continue "给出具体重构方案，写入 refactor-plan.md"
```

### 4.4 Fork：分支探索

```bash
# 从已有 session 分叉，不污染原对话链
opencode run --session ses_XXX --fork "尝试另一种实现方案"
```

适用场景：从同一上下文探索方案 A、方案 B，互不干扰。

### 4.5 Session 存储

| 项目 | 值 |
|------|-----|
| 存储位置 | `~/.local/share/opencode/opencode.db` (SQLite) |
| ID 格式 | `ses_` 前缀 + ULID（如 `ses_451cd8ae0ffegNQsh59nuM3VVy`） |
| 作用域 | 按项目目录隔离 |
| 管理命令 | `opencode session list` |

---

## 5. 进阶：ACP 协议编程式控制

OpenCode 支持 **Agent Communication Protocol (ACP)**，通过 JSON-RPC 进行程序化会话管理，适合生产级自动化。

### 5.1 启动 ACP 服务

```bash
opencode acp --cwd /path/to/project
```

### 5.2 核心方法

```json
// 创建新 session
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/new",
  "params": {
    "cwd": "/path/to/project",
    "mcpServers": []
  }
}

// 加载已有 session（恢复上下文）
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/load",
  "params": {
    "sessionId": "ses_451cd8ae0ffegNQsh59nuM3VVy",
    "cwd": "/path/to/project",
    "mcpServers": []
  }
}

// 发送 prompt
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123",
    "prompt": [
      { "type": "text", "text": "继续完善上一轮的方案" }
    ]
  }
}
```

### 5.3 Python 客户端示例

```python
import json
import websocket

class OpenCodeACP:
    def __init__(self, url="ws://127.0.0.1:4096"):
        self.ws = websocket.create_connection(url)
        self._id = 0

    def _call(self, method, params):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}
        self.ws.send(json.dumps(msg))
        return json.loads(self.ws.recv())

    def new_session(self, cwd):
        return self._call("session/new", {"cwd": cwd, "mcpServers": []})

    def load_session(self, session_id, cwd):
        return self._call("session/load", {"sessionId": session_id, "cwd": cwd, "mcpServers": []})

    def prompt(self, session_id, text):
        return self._call("session/prompt", {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": text}]
        })

# 使用示例
acp = OpenCodeACP()
session = acp.new_session("/root/myproject")
sid = session["result"]["sessionId"]

acp.prompt(sid, "分析 src/ 目录下的代码结构")
acp.prompt(sid, "根据上面的分析，重构 auth 模块")
acp.prompt(sid, "生成测试并写入 tests/")
```

---

## 6. CI/CD 与自动化集成

### 6.1 GitHub Actions

```yaml
name: OpenCode Code Review
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install OpenCode
        run: npm install -g opencode
      - name: Configure permissions
        run: |
          cat > opencode.json << 'EOF'
          {
            "permission": {"*": "allow", "question": "allow", "plan_enter": "allow", "plan_exit": "allow"}
          }
          EOF
      - name: Run Code Review
        env:
          OPENCODE_DISABLE_AUTOUPDATE: true
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          opencode run \
            --json \
            "Review this PR for security vulnerabilities and bugs. \
             Do not enter plan mode, do not ask questions. \
             Output results to review-report.md"
      - name: Upload Report
        uses: actions/upload-artifact@v4
        with:
          name: review-report
          path: review-report.md
```

### 6.2 通用 CI 脚本模板

```bash
#!/bin/bash
set -euo pipefail

export OPENCODE_DISABLE_AUTOUPDATE=true
export OPENCODE_DISABLE_WATCHER=true

# 确保权限配置
if [ ! -f opencode.json ]; then
    cat > opencode.json << 'EOF'
{"permission": {"*": "allow", "question": "allow", "plan_enter": "allow", "plan_exit": "allow"}}
EOF
fi

# 执行并捕获输出
opencode run --json "$1" 2>&1 | tee /tmp/opencode-output.log

# 检查退出码
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ OpenCode 任务失败"
    exit 1
fi

echo "✅ 完成"
```

---

## 7. 常见坑点与规避方案

### 7.1 Session Preset 覆盖权限

**现象**：`opencode.json` 中配置了 `"*": "allow"`，但 `question`、`plan_enter`、`plan_exit` 仍然被拒绝，agent 在需要用户决策时中断。

**原因**：Session 初始化时的内置 preset 会覆盖这三项为 `"deny"`（[#13851](https://github.com/anomalyco/opencode/issues/13851)）。

**规避**：
- 在 prompt 中明确禁止 plan mode 和提问：
  ```
  opencode run "直接执行以下任务。不要进入计划模式(plan mode)。
  不要询问任何问题(do not ask questions)。
  遇到选择自己决定，不需要用户确认。[你的任务]"
  ```
- 关注 [#10411](https://github.com/anomalyco/opencode/issues/10411) `--non-interactive` flag 的进展

### 7.2 Subagent 不继承权限

**现象**：主 agent 权限是 `allow`，但通过 TaskTool 派出的子 agent 仍然 `ask`，无人值守下**永久挂起**（[#12566](https://github.com/anomalyco/opencode/issues/12566)）。

**规避**：
- 在 prompt 中禁止使用子 agent：
  ```
  opencode run "... 不要使用子 agent(subagent/task tool)。
  所有操作由你自己执行。..."
  ```
- 或为子 agent 单独配置权限

### 7.3 交互式命令挂起

**现象**：`git commit` 弹出编辑器、`npm init` 等待输入、`apt-get install` 等待确认等。

**规避** — prompt 中明确指示：
```
执行所有 shell 命令时强制使用非交互标志：
- git commit → git commit -m "message"
- git merge → git merge --no-edit
- npm init → npm init -y
- apt-get install → apt-get install -y
- 禁止使用 vim/nano/less/more 等交互式程序
- 任何需要编辑器的操作改用 Write/Edit 工具
```

或安装 [opencode-shell-strategy](https://github.com/JRedeker/opencode-shell-strategy) 插件来系统性地解决。

### 7.4 多任务并行时的 Session 冲突

**现象**：多个 `opencode run` 同时操作同一 session，导致上下文错乱。

**规避**：每个任务链使用独立 session 文件：
```bash
opencode run --session "$(cat .opencode-sid-analyze)" "分析任务"
opencode run --session "$(cat .opencode-sid-refactor)" "重构任务"
```

### 7.5 长对话 Context 膨胀

**现象**：多轮持续对话后 context 过大导致速度变慢或截断。

**规避**：
- 定期 Fork 新 session 裁剪上下文
- 在 prompt 中要求阶段性总结，新 session 只传递总结

---

## 8. 参考资源

### 官方文档
- [OpenCode CLI 文档](https://opencode.ai/docs/cli/)
- [OpenCode 权限配置](https://opencode.ai/docs/permissions/)
- [OpenCode 配置文件详解](https://opencode.ai/docs/config/)

### 相关 Issue
- [#10411](https://github.com/anomalyco/opencode/issues/10411) — `--non-interactive` flag 提案
- [#13851](https://github.com/anomalyco/opencode/issues/13851) — CI 非交互流水线限制
- [#12566](https://github.com/anomalyco/opencode/issues/12566) — Subagent 不继承 allow 权限 bug
- [#5965](https://github.com/anomalyco/opencode/issues/5965) — SDK 级权限覆盖提案

### 相关工具
- [opencode-shell-strategy](https://github.com/JRedeker/opencode-shell-strategy) — 教 LLM 使用非交互 shell 标志
- [sessfind](https://docs.rs/crate/sessfind) — 跨 Agent session 搜索与恢复 TUI
- [agents-sesame](https://docs.rs/crate/agents-sesame) — 10+ Agent session 模糊搜索工具
- [OpenCode Autopilot](https://github.com/tarushvkodes/OpenCode-Autopilot) — VS Code 扩展，自动化批量任务队列

---

> 📅 最后更新：2026-06-11
>
> 🤖 本文档由 Claude (claude.ai/code) 辅助整理
