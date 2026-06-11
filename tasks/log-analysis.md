---
title: 应用日志错误分析
agent: analyzer
model: anthropic/claude-sonnet-4
timeout: 600
---

# 生产环境日志错误分析

## 分析目标
对指定应用的日志进行错误分类、根因分析和趋势对比。

## 数据源

按实际情况选择：

**本地日志文件:**
- 当前日志: `/var/log/app/app.log`
- 历史归档: `/var/log/app/archive/app-*.tar.gz`

**或 Windows 路径:**
- 当前日志: `C:\ProgramData\app\logs\app.log`
- 事件日志: `Get-EventLog Application -After (Get-Date).AddHours(-1)`

**或远程日志系统:**
- Loki: `http://loki:3100` (query: `{app="myapp"}`)
- Elastic: `http://elastic:9200/logs-*/_search`

## 分析步骤

### 1. 了解数据规模
```bash
ls -lh /var/log/app/app.log
wc -l /var/log/app/app.log
# Windows: dir C:\ProgramData\app\logs\app.log
```

### 2. 错误统计
```bash
# 按错误级别统计
grep -c "FATAL" /var/log/app/app.log
grep -c "ERROR" /var/log/app/app.log
grep -c "WARN" /var/log/app/app.log

# TOP 10 错误类型
grep "ERROR" /var/log/app/app.log | awk -F' - ' '{print $NF}' | sort | uniq -c | sort -rn | head
```

### 3. 时间分布
```bash
# 最近 1 小时的错误（按 10 分钟分桶）
grep "ERROR" /var/log/app/app.log | awk '{print $1" "$2}' | cut -c1-15 | uniq -c

# 最近 100 条完整错误
grep "ERROR" /var/log/app/app.log | tail -100
```

### 4. 对比历史趋势（可选）
```bash
# 从归档中提取过去 3 天同期的错误数
for f in /var/log/app/archive/app-$(date -d '1 day ago' +%Y%m%d)*.tar.gz; do
  echo "=== $(basename $f) ==="
  tar -xzf "$f" --to-stdout 2>/dev/null | grep -c "ERROR" || echo "0"
done
```

### 5. 关联分析（可选）
如果错误中包含 trace_id 或 request_id，提取几个具体 trace 的完整调用链：
```bash
TRACE_ID=$(grep "ERROR" /var/log/app/app.log | tail -1 | grep -oP 'trace_id=\K\S+')
grep "$TRACE_ID" /var/log/app/app.log
```

## 输出格式

报告写入 `/opt/opencode-agent/reports/log-analysis-$(date +%Y%m%d-%H%M).md`（Windows: `C:\opencode-agent\reports\`），包含：

1. **摘要**: 总行数 / ERROR 数 / 错误率 / 时间范围
2. **TOP 5 错误**: 类型、计数、占比、示例
3. **时间趋势**: 过去 24 小时错误数变化曲线（文字描述即可）
4. **根因推测**: 基于错误模式推断可能原因
5. **建议**: 修复优先级排序

## 约束
- 不要使用 read 工具加载大文件
- 所有数据提取用 bash 命令流式处理
- 压缩包使用 zgrep / tar --to-stdout 不解压
- Windows 上优先用 findstr / Get-Content -Tail 而非加载完整文件
