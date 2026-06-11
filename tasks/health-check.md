---
title: 部署机健康检查
agent: analyzer
model: anthropic/claude-sonnet-4
timeout: 300
---

# 部署机健康检查

## 检查目标
对部署机进行全面的资源、服务和日志健康检查。

## 检查项

### 1. 系统资源
```bash
# CPU / 内存 / 磁盘
top -bn1 | head -5          # 或: uptime && free -m && df -h
# Windows: Get-Counter '\Processor(_Total)\% Processor Time'
```

### 2. 关键服务
```bash
systemctl is-active myapp nginx docker 2>/dev/null || true
systemctl list-units --failed 2>/dev/null || true
# Windows: Get-Service -Name MyApp,Nginx | Select Name,Status
```

### 3. 磁盘使用率告警
```bash
df -h | awk '$5+0 > 80 {print "WARNING: "$0}'
# Windows: Get-PSDrive C | Where Used -gt 80
```

### 4. 最近错误日志（最近 10 条）
```bash
journalctl -u myapp --since "1 hour ago" -p err --no-pager | tail -10 2>/dev/null || true
# 或: tail -100 /var/log/app/error.log | grep -E "FATAL|ERROR" | tail -10
# Windows: Get-EventLog Application -After (Get-Date).AddHours(-1) -EntryType Error | Select -First 10
```

### 5. 网络连通性
```bash
# 检查关键端口监听
ss -tlnp | grep -E ':(80|443|4096|8080|3000)\b' 2>/dev/null || netstat -tlnp 2>/dev/null || true
# Windows: netstat -an | findstr "LISTENING" | findstr ":4096"
```

### 6. 最近系统事件
```bash
# 最近的重启/崩溃
last -n 5 2>/dev/null || last reboot -n 3 2>/dev/null || true
dmesg | tail -20 | grep -iE "error|fail|oom|killed" || true
# Windows: Get-WinEvent -LogName System -MaxEvents 20 | Where LevelDisplayName -match 'Error|Critical'
```

## 输出

写入 `/opt/opencode-agent/reports/health-check-$(date +%Y%m%d-%H%M).md`，包含：

1. 每个检查项的通过/告警/失败状态
2. 聚合告警（磁盘 > 80% / 服务 inactive / 内存 > 90%）
3. 建议操作

## 约束
- 只读诊断命令
- 不要修改任何系统配置
- Windows 上自动选择对应命令
