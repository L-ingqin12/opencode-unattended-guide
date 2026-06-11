---
title: 归档日志压缩包批量分析
agent: analyzer
model: anthropic/claude-sonnet-4
timeout: 900
---

# 归档日志压缩包批量分析

## 分析目标
对大量历史日志压缩包（.tar.gz / .zip / .gz）进行批量分析，不解压全部文件。

## 数据源

日志归档目录: `/var/log/app/archive/` 或 `C:\ProgramData\app\logs\archive\`

文件格式: `app-YYYYMMDD-HHMMSS.tar.gz` (每个约 50-200MB，共 30+ 个)

## 分析步骤

### 1. 了解归档规模
```bash
ls -lh /var/log/app/archive/ | head -20
echo "总文件数: $(ls /var/log/app/archive/*.tar.gz 2>/dev/null | wc -l)"
du -sh /var/log/app/archive/
```

### 2. 列出压缩包内容（不解压）
```bash
# 随机选一个压缩包看内部结构
tar -tzf $(ls /var/log/app/archive/*.tar.gz | head -1) | head -20
```

### 3. 从所有压缩包中统计 ERROR 总数
```bash
total=0
for f in /var/log/app/archive/*.tar.gz; do
  count=$(tar -xzf "$f" --to-stdout 2>/dev/null | grep -c "ERROR" || echo 0)
  echo "$(basename $f): $count"
  total=$((total + count))
done
echo "TOTAL ERRORS: $total"
```

### 4. 提取所有 ERROR 中的独特错误消息
```bash
# 从所有压缩包提取 ERROR 行中最后一段错误消息，按频率排序
for f in /var/log/app/archive/*.tar.gz; do
  tar -xzf "$f" --to-stdout 2>/dev/null | grep "ERROR" | awk -F' - ' '{print $NF}'
done | sed 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/<IP>/g' \
     | sed 's/[a-f0-9]\{8,\}/<ID>/g' \
     | sort | uniq -c | sort -rn | head -20
```

### 5. 提取特定错误类型的所有出现（跨所有归档）
```bash
# 选择 TOP 1 高频错误，提取它的所有出现
TOP_ERROR="<从步骤4获取的 TOP 错误模式>"
for f in /var/log/app/archive/*.tar.gz; do
  tar -xzf "$f" --to-stdout 2>/dev/null | grep "$TOP_ERROR"
done | awk '{print $1, $2}' | uniq -c
```

### 6. 选择最接近当前时间的有错误压缩包，逐日趋势

取最近 7 天每天的错误数（从归档文件名推断日期）：
```bash
for f in /var/log/app/archive/app-2026060*.tar.gz; do
  date_str=$(basename "$f" | grep -oP '\d{8}')
  count=$(tar -xzf "$f" --to-stdout 2>/dev/null | grep -c "ERROR" || echo 0)
  echo "$date_str: $count"
done
```

## 输出

写入 `/opt/opencode-agent/reports/archive-analysis-$(date +%Y%m%d-%H%M).md`，包含：

1. 归档概况（文件数、总大小、日志总行数估算）
2. 错误类型分布（TOP 20）
3. 每日/每周错误趋势
4. 异常时间点（错误突增的具体日期/小时）
5. 长期趋势总结和建议

## 约束
- **禁止解压全部文件**——全程用 `tar -xzf --to-stdout` 流式处理
- **禁止用 read 工具加载文件**——全部用 bash 命令
- 每个压缩包的处理时间控制在 30 秒内（用 timeout 保护）
- 如果归档数量 > 100 个，采样分析（取最近 30 个 + 均匀采样 20 个）
