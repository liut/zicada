---
date: 2026-07-31
topic: zicada-gen-service
---

# zicada gen-service 子命令

## Summary

添加 `zicada gen-service` 子命令，向 stdout 输出一份 systemd service unit 文件。用户自行重定向写入并 `systemctl enable/start`。自动注册、用户级服务等留到下一版。

---

## Problem Frame

zicada 以二进制形式发布，用户下载后需要手动编写 systemd unit 文件才能将服务器模式作为系统服务运行。写 unit 文件涉及确定二进制路径、拼写 ExecStart 参数、配置 Restart 策略等，对不熟悉 systemd 的用户是额外门槛。`gen-service` 消除这个手工步骤，用户只需重定向输出并 enable。

---

## Requirements

- R1. `zicada gen-service` 子命令存在，与 `-serv` / CLI add 同级调度
- R2. 向 stdout 输出完整 systemd service unit，包含 `[Unit]`、`[Service]`、`[Install]` 段
- R3. `ExecStart` 使用绝对路径，指向生成时 zicada 二进制所在位置
- R4. 端口和 DSN 从 `-port` / `-dsn` 参数读取，未指定时使用默认值（1353 / `redis://localhost:6379/0`）
- R5. `ExecReload` 使用 `kill -HUP $MAINPID`，利用已有 SIGHUP 处理实现 reload
- R6. `Restart=on-failure`，`Type=simple`

---

## Acceptance Examples

- AE1. **Covers R1-R4.** 执行 `zicada gen-service -port 2053`，stdout 输出包含 `ExecStart=.../zicada -serv -port 2053` 的合法 unit 文件
- AE2. **Covers R4.** 执行 `zicada gen-service`（无参数），stdout 输出使用默认端口 1353 和默认 DSN
- AE3. **Covers R2.** 输出可通过 `systemd-analyze verify -` 校验通过

---

## Success Criteria

- 用户执行 `zicada gen-service > /etc/systemd/system/zicada.service && systemctl daemon-reload && systemctl enable --now zicada` 后服务正常运行
- 生成的 unit 可通过 `systemctl reload zicada` 触发 SIGHUP reload

---

## Scope Boundaries

- 不自动写入文件（stdout 输出，用户自行重定向）
- 不调用 systemctl（enable/start/stop 由用户自行操作）
- 不区分 root / 用户级服务（仅生成系统级 unit 模板，用户自行决定安装位置）
- 不生成非 systemd 的 init 配置（launchd / OpenRC / runit）

### Deferred for later

- `zicada install` / `zicada remove` 子命令（自动写文件 + systemctl 操作）
- 用户级服务（`systemctl --user`）自动检测和注册

---

## Key Decisions

- **stdout 输出而非自动安装**：最小化权限依赖，用户自主决定安装位置，简化 v1 实现
- **仅生成系统级 unit**：用户级服务（`~/.config/systemd/user/`）使用场景差异大，留到下一版评估

---

## Dependencies / Assumptions

- 目标运行环境为 Linux + systemd
- 用户在生成 unit 后不挪动 zicada 二进制；若挪动需重新生成
- 绑定 privileged 端口（如 53）时用户需自行配置 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 或以 root 运行
