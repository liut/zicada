---
title: "feat: Add gen-service subcommand for systemd unit generation"
type: feat
status: completed
date: 2026-07-31
origin: docs/brainstorms/2026-07-31-gen-service-requirements.md
---

# feat: Add gen-service subcommand for systemd unit generation

## Summary

Add `zicada -gen-service` mode that prints a systemd service unit file to stdout. The unit auto-detects the binary path, reads `-port` and `-dsn` from CLI flags, and includes `ExecReload` via SIGHUP (already handled). User redirects stdout to install.

---

## Problem Frame

zicada ships as a standalone binary. Users who want the server mode running as a systemd service must hand-write a unit file — determining the binary path, constructing `ExecStart`, and configuring restart policy. `-gen-service` eliminates this manual step: generate, redirect, enable.

(see origin: `docs/brainstorms/2026-07-31-gen-service-requirements.md`)

---

## Requirements

- R1. `zicada -gen-service` subcommand exists, dispatched alongside `-serv` / CLI add in `main.zig`
- R2. Outputs complete systemd unit to stdout: `[Unit]`, `[Service]`, `[Install]`
- R3. `ExecStart` uses absolute binary path detected at generation time (`std.process.executablePathAlloc`)
- R4. Port and DSN from `-port` / `-dsn`, defaults 1353 / `redis://localhost:6379/0`
- R5. `ExecReload=/bin/kill -HUP $MAINPID` — leverages existing SIGHUP handler
- R6. `Restart=on-failure`, `Type=simple`

**Origin acceptance examples:** AE1 (gen-service -port 2053), AE2 (no-args defaults), AE3 (systemd-analyze verify)

---

## Scope Boundaries

- stdout-only output; no file write, no systemctl calls
- System-level unit only (no `--user` detection)
- systemd only (no launchd / OpenRC / runit)

### Deferred to Follow-Up Work

- `zicada install` / `zicada remove` subcommands (auto-write + systemctl)
- User-level service (`systemctl --user`) auto-detection

---

## Key Technical Decisions

- **Flag-driven dispatch (`-gen-service`), not positional subcommand**: follows the established pattern in `main.zig:82-84` where modes are selected by boolean flags. A positional-subcommand dispatcher would be a new convention inconsistent with the existing CLI surface.
- **Binary path via `std.process.executablePathAlloc`**: Zig 0.16's standard API (not `std.fs.selfExePath` which does not exist in this version). Path is snapshotted at generation time; moving the binary later requires regenerating the unit.
- **Template lives in `src/service.zig`**: follows the module-per-capability convention (`src/redis.zig`, `src/dns/server.zig`, etc.), keeps `main.zig` focused on orchestration, and enables unit-testing the template output independently of stdout.

---

## Implementation Units

### U1. Config: add `-gen-service` flag

**Goal:** Extend CLI flag parsing to recognize `-gen-service` as a boolean flag, and add the field to `Config`.

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Modify: `src/config.zig` (Config struct + parse)

**Approach:**
- Add `gen_service: bool` field to `Config` (default `false`)
- No allocation needed (boolean, like `serv`)
- Parse in the flag loop: match `-gen-service` and `-gen-service=true|1|false|0`, same pattern as `-serv` (`src/config.zig:91-105`)
- Add to `Defaults` struct: `const gen_service: bool = false;`
- Update `deinit` — no-op for a bool, no change needed

**Patterns to follow:** The `serv` boolean flag in `src/config.zig:51-56, 91-105` — presence-only sets true, `=true|1|false|0` explicit form, else `InvalidValue`.

**Test scenarios:**
- `-gen-service` (presence-only) → `cfg.gen_service == true`
- `-gen-service=true` / `-gen-service=1` → true
- `-gen-service=false` / `-gen-service=0` → false
- `-gen-service=maybe` → `error.InvalidValue`
- Default (no flag) → `cfg.gen_service == false`

**Verification:** `zig build test` — config tests pass for the new flag.

---

### U2. src/service.zig: systemd unit template

**Goal:** Provide a function that generates the complete systemd unit file text from a `Config`.

**Requirements:** R2, R3, R4, R5, R6

**Dependencies:** U1 (Config.gen_service field and flag parsing)

**Files:**
- Create: `src/service.zig`

**Approach:**
- Export `genUnit(allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8` — returns the full unit text
- Use `std.process.executablePathAlloc` to detect binary path. On error (unlikely on modern systems), return `error.SelfExePathUnavailable` — mapped to a clear stderr message in U3
- Template the unit file with three sections:
  - `[Unit]`: `Description=zicada DNS server`, `After=network.target`
  - `[Service]`: `Type=simple`, `ExecStart=<absolute_path> -serv -port <port> -dsn <dsn>`, `ExecReload=/bin/kill -HUP $MAINPID`, `Restart=on-failure`
  - `[Install]`: `WantedBy=multi-user.target`
- If `cfg.port` equals default (1353), omit `-port` from ExecStart; same for DSN default — keeps the generated unit clean for default configs
- Allocate the full text via `std.fmt.allocPrint`

**Patterns to follow:** `src/util.zig:52-59` `formatA` — `allocPrint` + caller frees.

**Test scenarios:**
- Happy path: `genUnit` with default config → output contains `[Unit]`, `[Service]`, `[Install]` sections; `ExecStart` line present with binary path; `ExecReload` present; `Restart=on-failure`; `Type=simple`
- Happy path: `genUnit` with custom port 2053 → `ExecStart` includes `-port 2053`
- Happy path: `genUnit` with custom DSN → `ExecStart` includes `-dsn <value>`
- Edge case: generated text does not contain unexpanded placeholders (`<port>`, `{port}`, etc.)
- Edge case: `ExecStart` path is absolute (starts with `/`)

**Verification:** `zig build test` — service module tests pass. Manual: `systemd-analyze verify <(zig-out/bin/zicada -gen-service)` on a Linux system (per AE3).

---

### U3. main.zig: dispatch `-gen-service` mode

**Goal:** Wire the `-gen-service` flag through `main.zig` so the binary prints the unit file and exits cleanly.

**Requirements:** R1

**Dependencies:** U1 (flag), U2 (template function)

**Files:**
- Modify: `src/main.zig`

**Approach:**
- Import `const service = @import("service.zig")` and add to the `comptime` registration block
- Add dispatch branch before `-serv` check: `if (cfg.gen_service) return runGenService(io, cfg);`
- Implement `fn runGenService(io: Io, cfg: *const config.Config) !u8`:
  - Call `service.genUnit(allocator, cfg)`
  - Write result to stdout via `io.writer()`
  - On `error.SelfExePathUnavailable`: print error to stderr, return 1
  - Return 0 on success
- Update `usage` text to include the new mode:

  ```
  zicada -gen-service [-port <n>] [-dsn <url>]
  ```

**Patterns to follow:** `runCliAdd` in `src/main.zig:94-148` — standalone function, error → stderr + non-zero exit, success → stdout + exit 0.

**Test scenarios:**
- Integration: `zicada -gen-service` exits 0, stdout is non-empty, contains `ExecStart=` and `[Unit]`
- Integration: `zicada -gen-service -port 2053` → output contains `-port 2053` in ExecStart
- Error path: if `executablePathAlloc` fails → exits non-zero with stderr message

**Verification:** `zig build run -- -gen-service` exits 0 and prints a valid-looking unit file to stdout. `zig build test` — the project builds and existing tests continue to pass.

---

## Verification

- `zig build test` — all tests pass (config + service template + existing)
- `zig-out/bin/zicada -gen-service` — prints unit file, exit 0
- `zig-out/bin/zicada -gen-service -port 2053` — `ExecStart` references port 2053
- `zig-out/bin/zicada -serv` — server mode still works (no regression)
- `zig-out/bin/zicada -name x -ip 10.0.0.1` — CLI add still works (no regression)

---

## Dependencies / Assumptions

- Zig 0.16 `std.process.executablePathAlloc` available and returns a real path on the target system
- Target systems run Linux + systemd; the generated unit references `/bin/kill` which is universal
- Users understand they must redirect stdout and run `systemctl daemon-reload` + `systemctl enable --now`
- Moving the binary after generation silently breaks the unit — users must regenerate
