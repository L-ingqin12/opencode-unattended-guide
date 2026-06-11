# OpenCode 实操专题：Web 界面 / 大文件分析 / 网络来源

> 补充三个实操缺口：什么时候用 `opencode web`？怎么分析 GB 级日志和压缩包？怎么从 URL/网络路径获取问题来源？

---

## 1. opencode web vs serve：何时用哪个

### 一句话区分

```
opencode serve  → 纯 HTTP API，给程序调用的（headless）
opencode web    → API + 浏览器 UI，给人用的
opencode web 内部跑的就是 serve，多了个前端界面而已
```

### 选择矩阵

| 你的场景 | 用这个 | 原因 |
|----------|--------|------|
| `otask.sh` 或脚本调用 | `serve` | 不需要 UI，更轻量 |
| CI/CD 流水线 | `serve` | headless 无攻击面 |
| Docker 容器后台运行 | `serve` | 省资源 |
| 人在浏览器里操作 | `web` | 有 UI |
| 手机上临时查看/操作 | `web` + Tailscale | 浏览器是唯一界面 |
| 演示/教学 | `web` | 对方不需要装任何东西 |
| 远程开发（本地 TUI 连接远程） | 远程 `serve`，本地 `opencode attach` | 最佳体验 |

### 在部署机上使用 web

```bash
# 启动（加密码）
OPENCODE_SERVER_PASSWORD=yourpassword opencode web --hostname 0.0.0.0 --port 4096

# 浏览器访问（同一局域网）
http://192.168.1.50:4096

# 或通过 Tailscale（任何地方）
http://100.64.0.2:4096
```

### 安全注意

- **版本 ≥ 1.1.10**（修复了 CVE-2026-22813 XSS 漏洞：恶意网站通过 `?url=` 参数注入命令）
- **必须设密码**：`OPENCODE_SERVER_PASSWORD`
- **不要暴露到公网**：用 Tailscale 私有网络或 nginx IP 白名单
- **web 攻击面大于 serve**：多一层前端路由 → 多一层风险。纯自动化场景用 `serve` 更安全

### 实操案例

```bash
# 案例 1: 部署机上的临时手动分析
# 在 Windows 部署机上，管理员打开浏览器就能用
opencode web --port 4096
# → 浏览器自动打开 http://localhost:4096
# → 输入 prompt: "分析 C:\ProgramData\app\logs\error.log 最近 1 小时的错误"

# 案例 2: 远程团队共享一台 GPU 开发机
# GPU 机器上
OPENCODE_SERVER_PASSWORD=teamsecret opencode serve --hostname 0.0.0.0 --port 4096
# 团队成员本地
opencode attach http://gpu-server:4096
# 或浏览器打开 http://gpu-server:4096（如果用 web 模式）

# 案例 3: Docker 一键部署
docker run -d --name opencode-agent \
  -p 4096:4096 \
  -e OPENCODE_SERVER_PASSWORD=secret \
  -v /opt/myapp:/workspace \
  ghcr.io/anomalyco/opencode serve --port 4096
```

---

## 2. 大文件与压缩包在线分析

### 核心问题

`opencode` 的 `read` 工具有 **50KB 硬限制**（且在限制检查前会把整个文件加载到内存）。对于生产环境动辄 GB 级的日志文件，`read` 工具完全不可用。

### 正确方案：让 Agent 用 bash 工具流式处理

**关键原则**：永远不要让 agent 用 `read` 工具读大文件。在 prompt 和 agent 定义中明确指示使用 bash 命令。

#### 2.1 纯文本大日志 (>1GB)

```markdown
---
title: 分析超大应用日志
agent: analyzer
---

/app/logs 下有一个 2.3GB 的 app.log，请分析其中的错误。

注意：日志文件很大，不要用 read 工具加载它。
请用以下 bash 命令进行流式分析：

1. 先用 wc -l 和 ls -lh 了解文件规模
2. 用 grep -c "ERROR" 统计错误总数
3. 用 grep "ERROR" | awk '{print $5}' | sort | uniq -c | sort -rn | head 获取 TOP 错误类型
4. 用 grep "ERROR" | tail -100 获取最近 100 条错误
5. 用 sed -n '/2026-06-11 10:/,/2026-06-11 11:/p' 提取特定时间窗口
```

#### 2.2 压缩包 (.tar.gz / .zip / .gz)

```markdown
---
title: 分析压缩日志包
agent: analyzer
---

/opt/logs/archive/ 下有 50 个 app-2026-06-*.tar.gz 日志压缩包（共 8GB）。

请不要解压全部文件。请用以下方式流式分析：

1. 列出压缩包结构（不解压）:
   tar -tzf app-2026-06-01.tar.gz | head -20

2. 直接从压缩包中搜索 ERROR（不解压）:
   tar -xzf app-2026-06-01.tar.gz --to-stdout | grep "ERROR" | head -50

3. 批量搜索所有压缩包:
   for f in /opt/logs/archive/*.tar.gz; do
     echo "=== $f ==="
     tar -xzf "$f" --to-stdout 2>/dev/null | grep -c "ERROR"
   done

4. 对 .gz 单文件直接用 zgrep（最快）:
   zgrep -c "ERROR" /var/log/app.log.*.gz

5. 对 .zip 文件:
   unzip -p app-2026-06-01.zip "*.log" | grep "ERROR" | head -50
```

#### 2.3 关键命令速查

| 场景 | 命令 | 说明 |
|------|------|------|
| `.gz` 单文件搜索 | `zgrep "pattern" file.gz` | 不解压直接搜索，最快 |
| `.tar.gz` 搜索 | `tar -xzf file.tar.gz --to-stdout \| grep "pattern"` | 流式解压，不落盘 |
| `.tar.gz` 列内容 | `tar -tzf file.tar.gz` | 只看不提取 |
| `.zip` 搜索 | `unzip -p file.zip "*.log" \| grep "pattern"` | 流式输出 |
| 大文件取尾部 | `tail -n 10000 huge.log \| grep "ERROR"` | 只看最近数据 |
| 大文件取时间范围 | `sed -n '/10:00/,/11:00/p' huge.log` | 精确时间窗口 |
| 大文件取特定行 | `sed -n '1000000,1001000p' huge.log` | 取第 100万~101万行 |
| 统计行数 | `wc -l huge.log` | 先了解规模 |
| 统计文件大小 | `du -h huge.log` 或 `ls -lh` | 先了解规模 |
| Windows 等效 | `findstr "ERROR" huge.log` | Windows 版 grep |
| Windows .zip | `Expand-Archive -Path x.zip -DestinationPath .` | 需解压（不如 Linux 方便） |

### 任务模板：日志分析

```markdown
---
title: 生产日志错误分析
agent: analyzer
machine: deploy-prod-01
directory: /opt/myapp
---

## 数据源
- 当前日志: /var/log/app/app.log (约 500MB，实时增长中)
- 历史归档: /var/log/app/archive/app-*.tar.gz (共 12 个文件，约 3GB)

## 分析步骤
1. 了解当前日志规模 (wc -l, ls -lh)
2. 统计最近 1 小时的 ERROR 总数
3. 提取 TOP 10 错误类型及出现次数
4. 对比过去 3 天同一时段的错误数量趋势（从归档中提取）
5. 对于 TOP 3 高频错误，各取 5 条完整 stacktrace

## 输出
写入 /opt/opencode-agent/reports/error-analysis-$(date +%Y%m%d).md

## 约束
- 不要使用 read 工具加载大文件
- 所有数据提取使用 bash 命令流式处理
- 压缩包使用 zgrep / tar --to-stdout 不解压分析
- 如操作预估超过 120 秒，分步执行并报告进度
```

---

## 3. 网络路径与 URL 来源分析

### 3.1 从 URL 获取数据

```markdown
# 任务: 分析来自 URL 的错误报告
请从以下 URL 获取数据并分析:
- https://internal-api.company.com/errors?service=auth&hours=24
- http://log-aggregator:3100/api/logs?tag=production

使用 curl 获取 JSON 格式数据，然后用 jq 分析。

# 如果是内网 API（需要认证）
curl -H "Authorization: Bearer $API_TOKEN" \
  "http://log-aggregator:3100/loki/api/v1/query?query={app=\"myapp\"}"
```

### 3.2 从网络共享路径 (SMB/NFS)

```markdown
# Linux: NFS 挂载点
mount -t nfs 192.168.1.100:/logs /mnt/remote-logs
ls /mnt/remote-logs/
zgrep "ERROR" /mnt/remote-logs/app-$(date +%Y%m%d).log.gz

# Windows: UNC 路径
dir \\192.168.1.100\logs\app\
findstr "ERROR" \\192.168.1.100\logs\app\app-20260611.log
```

### 3.3 从日志聚合系统 (Loki / ELK / Splunk)

```markdown
# Loki (Grafana)
curl -G -s "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={app="myapp"} |= "ERROR"' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=100' \
  | jq '.data.result[].values[]'

# Elasticsearch
curl -s "http://elastic:9200/logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"bool":{"must":[{"match":{"level":"ERROR"}},{"range":{"@timestamp":{"gte":"now-1h"}}}]}},"size":100}'
```

---

## 4. 任务文件完整示例

仓库 `tasks/` 目录下放了可直接使用的任务模板：

- `tasks/log-analysis.md` — 日志错误分析
- `tasks/archive-analysis.md` — 压缩归档日志分析
- `tasks/health-check.md` — 系统健康检查

用法：

```bash
# 编辑机器名和目标路径后直接提交
otask run tasks/log-analysis.md -t prod-01:4096
```

---

> 📅 2026-06-11
>
> 相关：[opencode-remote-dispatch-design.md](opencode-remote-dispatch-design.md) / [agent-security-guide.md](config/agent-security-guide.md)
