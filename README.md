# zicada

A small DNS server backed by Redis. Stores A records in a `dns-a-<name>` key
(zone-text value), answers A queries over UDP, accepts RFC 2136 UPDATE messages
over UDP, and exposes a tiny HTTP `PUT /api/dns/a` API for batch inserts.

Zig 0.16 rewrite of an internal Go service (`cupola/cicada`). Scope is
intentionally narrow: A records only, UDP only, no TSIG, no zone transfers, no
DNSSEC.

## Build

Requires Zig 0.16.

```bash
zig build              # debug binary at ./zig-out/bin/zicada
zig build -Doptimize=ReleaseFast
```

## Usage

### Add a record (CLI)

```bash
./zig-out/bin/zicada -name app.example.com -ip 10.0.0.1 -ttl 60
# writes Redis key: dns-a-app.example.com
#   value:        app.example.com. 60 IN A 10.0.0.1
```

Flags: `-name` (host), `-ip` (IPv4), `-ttl` (RR ttl, default 60),
`-days` (Redis key expiry in days, default 7).

### Run as server

```bash
./zig-out/bin/zicada -serv -port 1353 -dsn redis://127.0.0.1:6379/0
```

Listens on UDP `1353` (DNS) and TCP `1354` (HTTP). Responds to `SIGINT`,
`SIGTERM`, and `SIGHUP` within ~1s.

The HTTP listener binds on `-port + 1`. Pick `-port` with enough headroom
(the default 1353 leaves 1354 free; running on `-port 53` for a real DNS
listener needs root or `CAP_NET_BIND_SERVICE`).

Cross-compiling for Linux from macOS:

```bash
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
```

### Query (dig)

```bash
dig @127.0.0.1 -p 1353 app.example.com A +short
# 10.0.0.1
```

### Update (nsupdate or raw UDP)

The v1 server accepts UPDATE messages on UDP only. `nsupdate` defaults to TCP
for UPDATE and will not talk to this server — send the UPDATE as a raw UDP
datagram or use the smoke script as a working example
(`scripts/smoke.sh` → AE4).

### HTTP API

```bash
curl -X PUT --data '[{"name":"app.example.com","ip":"10.0.0.1"}]' \
     http://127.0.0.1:1354/api/dns/a
# ok
```

Batch insert; each entry becomes one Redis key.

## Smoke test

`scripts/smoke.sh` exercises the full pipeline (Redis lifecycle, CLI add,
HTTP PUT, dig query, UDP UPDATE). Needs `redis-server`, `redis-cli`, `dig`,
`curl`, and `python3` on PATH.

```bash
bash scripts/smoke.sh
```

Brings up Redis on `:6379` if not running, builds the binary, starts the
server, runs AE1–AE4 in sequence, and prints `ALL PASS` on success.

## Tests

```bash
zig build test
```

Integration tests require a running `redis-server` on `127.0.0.1:6379`;
they `SkipZigTest` otherwise. **Without Redis on `:6379`, `zig build test`
exits 0 with all tests skipped** — CI must run a Redis service for the test
job to mean anything.

## Scope boundaries (v1)

- A records only
- UDP transport only (TCP listener is deferred)
- Single Redis instance, single connection per process
- No TSIG, no prerequisites, no AXFR/IXFR

## Layout

```
src/
  main.zig          CLI flag parsing, server-mode orchestration, signal handlers
  log.zig           Structured logger (pretty in Debug, JSON in Release)
  config.zig        Flag parsing
  redis.zig         Minimal RESP client
  util.zig          IPv4 parse + zone-text A formatter
  dns/
    wire.zig        Header, name, question, A answer codec (RFC 1035 + RFC 2136)
    server.zig      UDP listener, query dispatch
    update.zig      RFC 2136 UPDATE handler (Redis SET/DEL)
  http/
    server.zig      HTTP PUT /api/dns/a handler
scripts/
  smoke.sh          End-to-end exerciser (AE1–AE4)
```