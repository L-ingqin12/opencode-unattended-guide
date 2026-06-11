# Agent 访问控制与安全加固

> 当 `opencode serve` 暴露到网络时，默认没有任何访问控制——所有 Agent、所有路径、所有工具都开放。本章提供完整的加固方案。

## 目录

1. [威胁模型](#威胁模型)
2. [三层防护架构](#三层防护架构)
3. [Layer 1: Agent 级白名单 + 目录沙箱](#layer-1-agent-级白名单--目录沙箱)
4. [Layer 2: nginx 访问控制](#layer-2-nginx-访问控制)
5. [Layer 3: 会话隔离](#layer-3-会话隔离)
6. [部署清单](#部署清单)

---

## 威胁模型

```
暴露 opencode serve 之后，攻击面:
  ┌──────────────────────────────────────────────┐
  │ POST /session  → 任意工作目录                  │
  │ POST /session/{id}/prompt → 任意 agent         │
  │      → agent 调用 bash → 任意命令               │
  │      → agent 调用 edit → 写入任意文件            │
  │      → agent 调用 read → 读取任意文件(含凭证)     │
  │ GET  /session      → 列出所有用户的 session     │
  │ GET  /session/{id} → 查看他人的对话记录          │
  └──────────────────────────────────────────────┘
```

**需要防御的 5 个维度:**

| # | 维度 | 风险 | 措施 |
|---|------|------|------|
| 1 | Agent 暴露面 | 攻击者使用非预期的 agent（如 builder/deployer） | Agent 白名单 — 仅 `mode: primary` 可见 |
| 2 | 工具权限 | agent 执行 `rm -rf /` 或读取 `/etc/shadow` | per-agent 权限 + 路径沙箱 |
| 3 | 目录穿越 | 通过 `directory` 参数访问任意路径 | nginx 校验 + opencode.json 路径限制 |
| 4 | 身份认证 | 单密码泄露 = 全权限 | nginx IP 白名单 / mTLS / 每用户独立实例 |
| 5 | 会话泄露 | 用户 A 看到用户 B 的 session | 每用户独立端口/实例 |

---

## 三层防护架构

```
Internet / 内网
     │
     ▼
┌─────────────────────────────────────┐
│ L1: Nginx 访问控制                   │
│  - IP 白名单 (allow 10.0.0.0/8)     │
│  - Rate limiting (10r/m)            │
│  - TLS 加密                          │
│  - TLS 客户端证书 (mTLS，可选)       │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ L2: opencode.json Agent 沙箱         │
│  - Agent 白名单 (仅 mode:primary)   │
│  - 路径沙箱 (read/edit/bash 限定)   │
│  - 子 agent 禁止 (task: deny)       │
│  - 外网隔离 (webfetch/websearch deny)│
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ L3: 会话隔离                         │
│  - 每用户独立端口/实例               │
│  - 或 Docker 容器隔离               │
│  - 会话数据互不可见                  │
└─────────────────────────────────────┘
```

---

## Layer 1: Agent 级白名单 + 目录沙箱

### 核心原则

只有 `mode: "primary"` 的 agent 能通过 API 选择。其他 agent 设为 `"subagent"` 或 `"hidden"`——从 API 视角它们不存在。

### 配置模板

见 [config/secure-opencode.json](config/secure-opencode.json)，关键点：

```json
{
  "default_agent": "analyzer",

  "agent": {
    "analyzer": {
      "mode": "primary",
      "permission": {
        "read": {
          "/var/log/**": "allow",
          "/opt/myapp/**": "allow",
          "*": "deny"
        },
        "edit": {
          "/opt/opencode-agent/reports/**": "allow",
          "*": "deny"
        },
        "bash": {
          "cat *": "allow",
          "grep *": "allow",
          "systemctl status *": "allow",
          "*": "deny"
        },
        "task": "deny",
        "webfetch": "deny",
        "websearch": "deny"
      }
    },

    "builder": {
      "mode": "hidden"
    },

    "deployer": {
      "mode": "hidden"
    }
  }
}
```

### 效果验证

```bash
# analyzer 可用 ✅
curl -X POST http://target:4096/session/{id}/prompt \
  -d '{"agent":"analyzer","parts":[{"type":"text","text":"分析日志"}],...}'

# builder 不可见 ❌
curl -X POST http://target:4096/session/{id}/prompt \
  -d '{"agent":"builder",...}'
# → 404 或回退到 default_agent

# 读取 /etc/shadow → 被 deny ❌
# 写入 /etc/passwd → 被 deny ❌
# 执行 rm -rf → 被 deny ❌
```

### Windows 路径沙箱

```json
{
  "read": {
    "C:\\ProgramData\\app\\**": "allow",
    "C:\\opencode-agent\\**": "allow",
    "*": "deny"
  },
  "bash": {
    "Get-EventLog *": "allow",
    "type *": "allow",
    "findstr *": "allow",
    "*": "deny"
  }
}
```

---

## Layer 2: nginx 访问控制

在 [nginx/opencode-upstream.conf](nginx/opencode-upstream.conf) 基础上叠加：

### IP 白名单

```nginx
# 仅允许内网 + Tailscale + 特定 CI IP
allow 10.0.0.0/8;
allow 172.16.0.0/12;
allow 192.168.0.0/16;
allow 100.64.0.0/10;   # Tailscale
allow 10.10.10.100;     # CI 服务器
deny all;               # 拒绝其他所有
```

### 目录参数校验

```nginx
# 阻止 session 创建时使用可疑目录
location = /session {
    # 只允许 POST（不允许 GET 列出所有 session）
    limit_except POST { deny all; }

    # 拒绝包含 .. 或 /etc/ 或 /root/ 的请求体
    if ($request_body ~* "(\.\.[\\/]|/etc/|/root/|C:\\Windows)") {
        return 403 "Forbidden directory";
    }

    proxy_pass http://opencode_backend;
    proxy_read_timeout 600s;
    proxy_buffering off;
}
```

### 端点访问控制

```nginx
# 会话列表：完全禁止（防止信息泄露）
location = /session {
    limit_except POST { deny all; }
    # ...
}

# 会话详情：只允许自己的 session（需额外认证逻辑）
# 简单方案：直接禁止 GET /session（阻断列表和信息泄露）
location ~ ^/session/[^/]+$ {
    limit_except POST DELETE { deny all; }
    # ...
}

# 健康检查：允许任意访问
location = /healthz {
    allow all;
    # ...
}
```

### mTLS（高安全场景）

```nginx
server {
    listen 443 ssl;
    ssl_client_certificate /etc/nginx/certs/ca.crt;
    ssl_verify_client on;          # 强制客户端证书
    ssl_verify_depth 2;

    # 无有效证书 → 拒绝
    if ($ssl_client_verify != SUCCESS) {
        return 403;
    }
}
```

---

## Layer 3: 会话隔离

### 方案 A：每用户独立端口（最简单）

```bash
# 用户 A
opencode serve --port 4096 --hostname 127.0.0.1
# 用户 B
opencode serve --port 4097 --hostname 127.0.0.1

# nginx 按用户路由
# /user-a/ → http://127.0.0.1:4096/
# /user-b/ → http://127.0.0.1:4097/
```

优点：session 数据物理隔离。缺点：每个用户占一个进程。

### 方案 B：Docker 容器隔离

```bash
# 每个用户一个容器，完全隔离
docker run -d --name opencode-user-a \
  -v /opt/user-a:/workspace \
  -v ./secure-opencode.json:/workspace/opencode.json \
  -e OPENCODE_SERVER_PASSWORD=xxx \
  -p 4096:4096 \
  ghcr.io/anomalyco/opencode serve --port 4096
```

优点：最强的隔离，可限制 CPU/内存/磁盘。缺点：需要 Docker。

### 方案 C：`OPencode_SERVER_PASSWORD` 旋转 + Session 清理

临时用户的方案——用完即删：

```bash
# 生成一次性密码
PASS=$(openssl rand -hex 16)

# 启动 serve（带密码）
OPENCODE_SERVER_PASSWORD=$PASS opencode serve --port 4096 &

# 使用
export OTASK_PASSWORD=$PASS
otask run task.md -t host:4096

# 完成后清理
otask sessions -t host:4096 | jq -r 'keys[]' | xargs -I{} curl -X DELETE http://host:4096/session/{}
```

---

## 部署清单

```
安全加固检查清单:

□ 1. opencode.json 中只有 mode=primary 的是你要暴露的 agent
□ 2. 每个 agent 有明确的路径白名单 (read/edit/bash)
□ 3. bash 使用命令前缀白名单 (如 "cat *", "grep *")，不允许 "*": "allow"
□ 4. task 设为 "deny"（禁止派生子 agent）
□ 5. webfetch/websearch 设为 "deny"（除非需要）
□ 6. plan_enter/plan_exit/question 设为 "deny"
□ 7. OPENCODE_SERVER_PASSWORD 设置为强密码
□ 8. nginx IP 白名单限制允许的来源
□ 9. nginx 阻断 /session GET（防止列表泄露）
□ 10. nginx 校验请求体不包含 .. /etc/ /root/ C:\Windows
□ 11. 生产环境启用 TLS (Let's Encrypt)
□ 12. 定期轮换密码
□ 13. 定期审计 nginx access log
□ 14. 多个用户使用独立端口/容器
```

---

> 📅 2026-06-11
>
> 相关文件: [config/secure-opencode.json](config/secure-opencode.json), [nginx/opencode-upstream.conf](nginx/opencode-upstream.conf)
