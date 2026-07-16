---
date: 2026-07-13
topic: zig-cicada-dns-server
---

# Zig 实现 Cicada DNS 服务器

## Summary

用 Zig 从头实现一个轻量级 DNS 服务器（命名为 zicada），完整支持 DNS 查询响应、nsupdate 动态更新、HTTP API 管理记录、Redis 持久化存储。定位与 Go 版 cicada 一致，利用 Zig 的性能、静态链接和小二进制优势，服务于 CI/CD 场景的动态 DNS 管理。

---

## Problem Frame

cicada 是用 Go 编写的 DNS 服务器，用于 CI/CD 环境中动态管理 DNS 记录。当前痛点：

1. **Go 二进制较大** — 动态链接时 10MB+，影响容器镜像体积
2. **跨平台支持** — 需要为不同平台编译，Zig 交叉编译更便捷
3. **资源受限环境** — IoT/嵌入式场景需要更小的二进制和更低内存占用

Zig 的优势：静态链接、无运行时依赖、更小的二进制（预计 < 1MB）、原生交叉编译。

---

## Actors

- A1. **CI/CD Pipeline** — 通过 HTTP API 或 CLI 添加/更新 DNS 记录
- A2. **运维人员** — 通过 CLI 或 HTTP API 管理记录
- A3. **nsupdate 客户端** — 支持 RFC 2136 动态更新协议的程序（如 `nsupdate` 命令）
- A4. **DNS 查询客户端** — 解析本地域名的任何 DNS 客户端

---

## Key Flows

- F1. **添加 DNS 记录（CLI 模式）**
  - **Trigger:** 用户执行 `zicada add -name app -ip 10.0.0.1`
  - **Actors:** A2
  - **Steps:** 解析参数 → 连接 Redis → 写入 `dns-a-<name>` 键值对（带 TTL）→ 返回成功
  - **Outcome:** DNS 记录已存入 Redis，可被 DNS 服务器查询到
  - **Covered by:** R1, R5

- F2. **添加 DNS 记录（HTTP API）**
  - **Trigger:** HTTP PUT 请求到 `/api/dns/a`
  - **Actors:** A1
  - **Steps:** 接收 JSON `[{name, ip}]` → 解析验证 → 批量写入 Redis → 返回 "ok"
  - **Outcome:** 批量 DNS 记录已存入 Redis
  - **Covered by:** R2, R6

- F3. **DNS 查询响应**
  - **Trigger:** DNS UDP 查询到达服务器端口（默认 1353）
  - **Actors:** A4
  - **Steps:** 解析 DNS 查询报文 → 从 Redis 查找 `dns-a-<name>` → 构造响应 → 返回 A 记录
  - **Outcome:** 查询者收到正确的 IP 地址或 NXDOMAIN
  - **Covered by:** R3, R7

- F4. **nsupdate 动态更新**
  - **Trigger:** RFC 2136 UPDATE 报文到达 DNS 端口
  - **Actors:** A3
  - **Steps:** 解析 UPDATE 报文 → 提取 zone 和 rrset → 添加/删除 Redis 中的记录 → 返回 SUCCESS
  - **Outcome:** DNS 记录通过 nsupdate 协议动态更新
  - **Covered by:** R4, R8

---

## Requirements

**[Core Functionality]**

- R1. CLI 模式支持添加 DNS A 记录（`-name`, `-ip`, `-ttl` 参数）
- R2. HTTP API 支持 PUT `/api/dns/a`，接受 JSON 数组 `[{name, ip}]`，返回 "ok\n"
- R3. DNS 服务器模式（UDP）监听指定端口，响应 A 记录查询
- R4. 支持简化的 nsupdate（RFC 2136）UPDATE 操作

**[Storage]**

- R5. Redis 作为后端存储，key 格式为 `dns-a-<lowercase-name>`
- R6. 记录支持 TTL（默认 7 天），Redis 自动过期
- R7. DNS 查询时从 Redis 读取，不存在返回 NXDOMAIN

**[Server Mode]**

- R8. 启动模式：`-serv` 启用服务器，同时运行 DNS（端口）和 HTTP API（端口+1）
- R9. 支持信号处理（SIGINT/SIGTERM）优雅关闭

**[Configuration]**

- R10. 通过 CLI 参数配置：端口（`-port`）、Redis DSN（`-dsn`）、默认 TTL 等
- R11. 配置参数有合理默认值

---

## Acceptance Examples

- AE1. **Covers R1.** 给定 Redis 运行中，当执行 `zicada add -name test -ip 192.168.1.100`，Redis 中应存在键 `dns-a-test`，值为 `192.168.1.100`
- AE2. **Covers R2.** 给定服务器运行中，当发送 `PUT /api/dns/a` 请求体 `[{"name":"app","ip":"10.0.0.5"}]`，应返回 `ok\n`
- AE3. **Covers R3.** 给定 `dns-a-app=10.0.0.1` 存在于 Redis，当收到 `dig @localhost app A`，应返回包含 `10.0.0.1` 的 A 记录响应
- AE4. **Covers R4.** 给定 nsupdate 客户端发送 UPDATE 报文添加 `app.example.com A 10.0.0.1`，Redis 中应创建对应记录

---

## Success Criteria

- 用户能够通过 CLI 添加 DNS 记录并通过 dig 验证查询结果
- 用户能够通过 HTTP API 批量添加记录
- nsupdate 客户端能够成功动态更新 DNS 记录
- 二进制体积显著小于 Go 版 cicada（目标 < 1MB）
- 能够在 macOS 开发编译，在 Linux 服务器运行

---

## Scope Boundaries

- 仅支持 A 记录类型（不包含 AAAA、CNAME、MX 等）
- nsupdate 为简化实现，不完全遵循 RFC 2136 所有细节
- DNS 服务器仅支持 UDP（TCP 作为可选后续功能）
- 不支持 zone transfer（AXFR/IXFR）

### Deferred for later

- AAAA 记录支持
- TCP DNS 查询支持
- 完整的 RFC 2136 兼容性
- DNSSEC 支持

### Outside this product's identity

- 作为通用 DNS 服务器（仅面向 CI/CD 场景的简单 A 记录管理）
- 作为域名注册商或权威 DNS 服务器

---

## Key Decisions

- **纯 Zig 标准库手写协议解析**：最小化外部依赖，适合嵌入式和跨平台场景
- **仅支持 A 记录**：与 cicada 保持一致，简化实现复杂度
- **Redis key 格式 `dns-a-<name>`**：保持与 cicada 相同的存储格式
- **HTTP API 端口 = DNS 端口 + 1**：与 cicada 一致的设计

---

## Dependencies / Assumptions

- Zig 编译器（推荐最新 stable 版本）
- Redis 服务器（任何兼容 go-redis/v9 协议的版本）
- 网络权限（绑定 privileged 端口需要 root 或 CAP_NET_BIND_SERVICE）

---

## Outstanding Questions

### Resolve Before Planning

- [User] 是否需要支持配置文件（如 YAML/TOML）而非仅 CLI 参数？

### Deferred to Planning

- [Technical] Zig 标准库网络 API 的 DNS 协议解析能力评估
- [Technical] Redis RESP 协议手写实现的复杂度评估
- [Needs research] Zig DNS 库生态是否有成熟可用的？
