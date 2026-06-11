# Nginx 接入层部署指南

为 `opencode serve` 添加 nginx 反向代理，获取生产级的并发控制、限流、TLS 终止和负载均衡能力。

## 为什么需要 Nginx

`opencode serve` 是一个简单的 HTTP 服务器，缺少：

| 能力 | opencode serve 原生 | nginx 补充 |
|------|---------------------|------------|
| **TLS/HTTPS** | ❌ | ✅ Let's Encrypt 自动续签 |
| **请求限流** | ❌ | ✅ 每 IP 10 req/m，创建 3 req/m |
| **并发控制** | ❌ | ✅ 每 IP 3 并发连接 |
| **负载均衡** | ❌ | ✅ 多实例分发 (least_conn) |
| **健康检查** | ❌ | ✅ 自动剔除故障实例 |
| **长连接复用** | ❌ | ✅ keepalive 32 |
| **SSE 无损代理** | N/A | ✅ proxy_buffering off |
| **访问日志** | 简单 stdout | ✅ JSON 格式结构化日志 |
| **请求体限制** | ❌ | ✅ client_max_body_size 10m |

## 快速部署

### 1. 安装 nginx

```bash
# Ubuntu/Debian
apt-get install -y nginx certbot python3-certbot-nginx

# CentOS/RHEL
yum install -y nginx certbot python3-certbot-nginx
```

### 2. 配置限流参数

```bash
# 将限流 zone 定义追加到 /etc/nginx/nginx.conf 的 http {} 块末尾
cat nginx/nginx-http-block.conf >> /etc/nginx/nginx.conf
```

### 3. 启用站点

```bash
# 复制站点配置
cp nginx/opencode-upstream.conf /etc/nginx/sites-available/opencode
ln -s /etc/nginx/sites-available/opencode /etc/nginx/sites-enabled/

# 检查语法
nginx -t

# 重载
systemctl reload nginx
```

### 4. 配置上游实例

根据实际情况调整 `upstream opencode_backend`：

```nginx
# 场景 A：1 台机器 3 个 opencode 实例（不同端口，避免单点）
upstream opencode_backend {
    least_conn;        # 最少连接算法（适合长任务）
    server 127.0.0.1:4096 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:4097 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:4098 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

# 场景 B：3 台独立机器（物理隔离）
upstream opencode_backend {
    least_conn;
    server 192.168.1.10:4096 max_fails=3 fail_timeout=10s;
    server 192.168.1.11:4096 max_fails=3 fail_timeout=10s;
    server 192.168.1.12:4096 max_fails=3 fail_timeout=10s;
    keepalive 32;
}
```

### 5. 测试

```bash
# 健康检查
curl -I https://opencode.yourcompany.com/healthz
# → HTTP/2 200

# 创建 session
curl -X POST https://opencode.yourcompany.com/session \
  -H 'Content-Type: application/json' \
  -d '{"directory":"/opt/myapp"}'
# → {"id":"sess_xxx"}

# 测试限流
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" https://opencode.yourcompany.com/healthz
done
# 超出限制 → 503 Service Unavailable
```

## 限流策略

### 默认策略

| 维度 | 限制 | 说明 |
|------|------|------|
| 全局请求频率 | 10 req/min/IP | 正常使用足够，防止异常 |
| Session 创建 | 3 req/min/IP | 防止批量创建 session |
| 并发连接 | 3 / IP | 允许 Controller 同时监控 3 个 session |
| 突发容忍 | burst=20 | 短时超量不直接拒绝，排队处理 |

### 调优建议

根据团队规模调整：

```nginx
# 大团队 (10+ 开发者)
limit_req_zone $binary_remote_addr zone=opencode_req:10m rate=30r/m;

# 自动化 CI 专用 IP（不限流）
geo $limit_bot {
    default 1;
    10.0.0.0/8 0;           # 内网不限
    192.168.1.100/32 0;     # CI 服务器不限
}
limit_req zone=opencode_req burst=20 nodelay;
limit_req_status 429;       # 返回 429 而非默认 503
```

## 多实例注意事项

### Session 亲和性

`opencode serve` 的 session 数据存储在本地 SQLite：
- **同一台机器多实例**：不同端口的实例有独立 DB，session 不互通
- **跨机器**：session 分布在各自机器
- **结论**：新 session 创建请求可负载均衡，但**后续 session 操作必须路由到同一后端**

如果你的 `dispatch.sh` 直接指定机器 IP（不走 nginx upstream），则不需要亲和性。如果走 nginx，推荐方式：

```nginx
# 方案 1：基于 IP hash 的亲和性
upstream opencode_backend {
    ip_hash;   # 同 IP 总是路由到同一后端
    server 192.168.1.10:4096;
    server 192.168.1.11:4096;
}

# 方案 2：Controller 直接连部署机 IP（绕过 nginx upstream）
# dispatch.sh 保持对部署机的直连，nginx 仅做 TLS + 限流 + 日志
```

### 但生产环境的推荐做法是：

Controller 通过 Tailscale/VPN 直连部署机，不经过中心化 nginx：
- 路径更短
- 不需要 session 亲和性处理
- 每台部署机前面放各自的 nginx（只做 TLS + 限流）

## 防盗链 / IP 过滤

```nginx
# 只允许内网和特定 IP
allow 10.0.0.0/8;
allow 172.16.0.0/12;
allow 192.168.0.0/16;
allow 100.64.0.0/10;    # Tailscale
deny all;
```
