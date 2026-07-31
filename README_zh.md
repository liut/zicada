# zicada

一个基于 Redis 的小型 DNS 服务器。A 记录存储在 `dns-a-<name>` 键中（zone-text
格式值），通过 UDP 响应 A 记录查询，通过 UDP 接收 RFC 2136 UPDATE 消息，并暴露
一个轻量级的 HTTP `PUT /api/dns/a` 接口用于批量写入。

基于 Zig 0.16 重写的内部 Go 服务 [cicada](https://github.com/liut/cicada)。功能范围
有意保持精简：仅支持 A 记录、仅 UDP、无 TSIG、无区域传输、无 DNSSEC。

## 构建

需要 Zig 0.16。

```bash
zig build              # debug 版本输出到 ./zig-out/bin/zicada
zig build -Doptimize=ReleaseFast
```

## 用法

### 添加记录（CLI）

```bash
./zig-out/bin/zicada -name app.example.com -ip 10.0.0.1 -ttl 60
# 写入 Redis 键: dns-a-app.example.com
#   值:            app.example.com. 60 IN A 10.0.0.1
```

参数：`-name`（主机名）、`-ip`（IPv4 地址）、`-ttl`（RR TTL，默认 60）、
`-days`（Redis 键过期天数，默认 7）。

### 以服务器模式运行

```bash
./zig-out/bin/zicada -serv -port 1353 -dsn redis://127.0.0.1:6379/0
```

在 UDP `1353`（DNS）和 TCP `1354`（HTTP）上监听。约 1 秒内响应 `SIGINT`、
`SIGTERM` 和 `SIGHUP`。

HTTP 监听端口为 `-port + 1`。选择 `-port` 时应留有足够余地（默认 1353 对应
1354 空闲；如果使用 `-port 53` 作为真实 DNS 监听端口，则需要 root 权限或
`CAP_NET_BIND_SERVICE`）。

从 macOS 交叉编译到 Linux：

```bash
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
```

### 查询（dig）

```bash
dig @127.0.0.1 -p 1353 app.example.com A +short
# 10.0.0.1
```

### 更新（nsupdate 或原始 UDP）

v1 服务器仅通过 UDP 接收 UPDATE 消息。`nsupdate` 默认使用 TCP 发送 UPDATE，
无法与此服务器通信——请以原始 UDP 数据报方式发送 UPDATE，或参考冒烟测试脚本
（`scripts/smoke.sh` → AE4）作为可运行的示例。

### HTTP API

```bash
curl -X PUT --data '[
  {"name":"app1.example.com","ip":"10.0.0.1"},
  {"name":"app2.example.com","ip":"10.0.0.2"},
  {"name":"app3.example.com","ip":"10.0.0.3"}
]' http://127.0.0.1:1354/api/dns/a
# ok
```

请求体为 JSON 数组，每个条目对应一个 Redis 键。异常条目（跳过/格式错误的 IP、
Redis 错误）将被跳过并记录日志，其余条目仍会写入——不提供事务保证，对于已接受
的请求，响应始终为 `ok`。

## 冒烟测试

`scripts/smoke.sh` 覆盖完整流水线（Redis 生命周期、CLI 添加、HTTP PUT、dig
查询、UDP UPDATE）。需要 `redis-server`、`redis-cli`、`dig`、`curl` 和
`python3` 在 PATH 中。

```bash
bash scripts/smoke.sh
```

如果 Redis 未运行，会在 `:6379` 上启动，构建二进制文件，启动服务器，依次运行
AE1–AE4，成功后输出 `ALL PASS`。可通过 `ZICADA_SMOKE_PORT=<port>` 覆盖端口。
各 AE 覆盖的内容及测试框架约定详见 `AGENTS.md`。

## 测试、架构与功能范围

贡献者和 AI Agent 文档位于 `AGENTS.md`——模块布局、范围边界、日志拆分
（`log.zig` 与 `std.log`）、DNS-join / HTTP-detach 线程模型，以及
`zig build test` 的注意事项。
