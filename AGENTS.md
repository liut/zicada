# AGENTS.md

Notes for agents and contributors working on `zicada`. End-user docs live in
`README.md`; origin requirements live in `docs/brainstorms/zicada-requirements.md`
and the implementation plan lives in `docs/plans/2026-07-13-001-feat-zicada-dns-server-plan.md`.

## What this is

A small DNS server backed by Redis. UDP listener answers A queries from
Redis (`dns-a-<name>` key, zone-text value), accepts RFC 2136 UPDATE messages
over UDP, and exposes `PUT /api/dns/a` on TCP for batch inserts. v1 is
intentionally narrow: A records only, UDP only, single Redis connection,
no TSIG.

## Layout

```
src/
  main.zig          Server-mode orchestration: thread spawn, signal handlers,
                    graceful shutdown (~1s on SIGINT/SIGTERM/SIGHUP)
  log.zig           Structured logger: pretty in Debug, JSON in Release.
                    Reserved for lifecycle events emitted from main.zig.
  config.zig        CLI flag parsing
  redis.zig         RESP client (PING/SET/GET/DEL); single TCP connection
  util.zig          parseIPv4 + formatA (the zone-text writer)
  dns/
    wire.zig        Header / name / question / A answer codec
                    (RFC 1035 + RFC 2136 UPDATE decode)
    server.zig      UDP listener; per-datagram arena; opcode dispatch
                    (QUERY → handleQuery, UPDATE → dns/update.zig)
    update.zig      UPDATE handler: zone must be SOA/IN, walks update
                    section, applies each RR via redis SET/DEL
  http/
    server.zig      HTTP listener on port+1; PUT /api/dns/a batch insert
scripts/
  smoke.sh          End-to-end exerciser (AE1–AE4), bash + inline Python
docs/
  brainstorms/      Origin requirements doc
  plans/            Origin implementation plan (U1–U9)
```

## Scope boundaries (v1)

- A records only (no AAAA / CNAME / MX / NS)
- UDP transport only (TCP DNS listener deferred — see plan §"Scope boundaries")
- Single Redis instance, single connection per process
- No TSIG, no prerequisite checks, no AXFR/IXFR, no DNSSEC

Deferred work that the plan calls out for later units: TCP listener, AAAA,
full RFC 2136 compliance (prerequisites + TSIG), CI release pipeline.

## Code conventions

### Logging split

There are two loggers and the codebase uses both:

- `log.zig` (`log.event`) — for **lifecycle events** emitted from `main.zig`
  (start, shutdown). Format depends on `builtin.mode`: pretty in Debug,
  JSON in Release. The README's "pretty in Debug, JSON in Release" promise
  applies **only** to these events.
- `std.log.warn|err|info` — for **per-request diagnostics** emitted from
  worker threads (`dns/server.zig`, `dns/update.zig`, `http/server.zig`,
  `redis.zig`). Always emits raw text, never JSON. Don't "upgrade" these
  to `log.event` without a cross-repo refactor — the split is deliberate
  (per-request emission must be allocator-free; `log.zig` requires a
  caller-supplied scratch buffer that worker threads don't carry).

When in doubt about which to use: lifecycle = `log.zig`, per-request = `std.log`.

### Thread model

`runServer` in `main.zig` spawns two threads and uses an atomic shutdown flag:

- **DNS thread** — `std.Thread.spawn` + `thread.join`. The receive loop
  polls shutdown between `receiveTimeout` calls (~500ms cadence), so it
  drains within ~1s.
- **HTTP thread** — `std.Thread.spawn` + `thread.detach`. `Server.accept`
  blocks indefinitely and there is no timeout variant in Zig 0.16's
  `std.Io.net.Server`, so the thread cannot observe the shutdown flag.

The shutdown dance is: signal handler flips `g_shutdown` (module-scope
atomic, async-signal-safe store); main thread polls it via a sleep loop;
on exit, `dns_thread.join()` then `http_thread.detach()`.

### Error reporting contract

- DNS decode / UPDATE apply failures: `std.log.warn(...)` + reply with the
  matching RCODE (FORMERR for malformed header/name, SERVFAIL for anything
  else). The reply is always built so the client gets a structured answer.
- Redis client failures: warn + reply SERVFAIL or HTTP 5xx.
- Socket bind failures: log err + exit; the process won't run half-bound.

## Testing

```bash
zig build test
```

Integration tests in `src/dns/update.zig`, `src/dns/server.zig`, and
`src/http/server.zig` open a real `redis-server` on `127.0.0.1:6379`. When
Redis isn't reachable they `SkipZigTest` — `zig build test` therefore
**exits 0 with all tests skipped** when Redis is absent. CI must run a
Redis service for `zig build test` to mean anything; not running one is
not the same as running no tests.

## Smoke test

`scripts/smoke.sh` is the end-to-end exerciser — `bash scripts/smoke.sh`
runs AE1–AE4 in sequence:

- **AE1**: CLI add writes Redis (`dns-a-<name>` zone-text value).
- **AE2**: HTTP PUT returns `ok`, redis-cli verifies, dig round-trips the
  inserted record back through DNS.
- **AE3**: dig A query returns the inserted record.
- **AE4**: raw UDP UPDATE (Python heredoc — `nsupdate` defaults to TCP
  and v1 is UDP-only) replaces the A record; dig confirms the new IP.

It brings up Redis on `:6379` if not running (writes-to-disk disabled, no
append-only file — pure in-memory for the test run), builds the binary,
prints each step before it runs, and tails the server log on any assertion
failure. Override the test port via `ZICADA_SMOKE_PORT`.

## Adding a new record type

The wire codec (`dns/wire.zig`) is shaped around A records; adding AAAA
or MX means extending `RR`, the encoder/decoder pair, `parseZoneTextA`
in `dns/server.zig`, and adding a Redis key family. The plan treats AAAA
as deferred; if you pick this up, do the codec + dispatch + Redis layout
in one commit (the Redis key format is a load-bearing contract — both
writer and reader must agree).
