# OpenCode 无人值守与持续对话指南

OpenCode 零交互、不间断任务执行的完整配置方案。覆盖权限消除、Session 管理、ACP 协议、CI/CD 集成和常见坑点规避。

## 快速开始

```bash
# 1. 配置全局放行权限
echo '{"permission": "allow"}' > opencode.json

# 2. 非交互执行单次任务
opencode run "你的任务" --json

# 3. 多轮持续对话
opencode run "第一步任务"
opencode run --continue "基于上一步，继续执行..."
opencode run --continue "继续深入..."
```

## 文档结构

- 权限配置：消除所有交互中断
- 持续对话：Session 管理 (`--continue` / `--session` / Fork / ACP)
- CI/CD 集成：GitHub Actions 模板
- 常见坑点：5 个已知问题及规避方案

## 许可

MIT
