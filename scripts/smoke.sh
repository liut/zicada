#!/usr/bin/env bash
# scripts/smoke.sh — full end-to-end smoke for zicada.
#
# Brings up Redis, builds the binary, and exercises AE1-AE4:
#   AE1: CLI add writes Redis
#   AE2: HTTP PUT /api/dns/a returns ok
#   AE3: dig A query returns the inserted record
#   AE4: raw UDP UPDATE changes the record and dig reflects the new value
#
# Exits 0 on success, non-zero on the first failed assertion. Each step
# prints what it's about to do so a run on a fresh box is debuggable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/zicada"
DSN="redis://127.0.0.1:6379/0"
PORT="${ZICADA_SMOKE_PORT:-15353}"
NAME="smoke.example.com"
TTL=60
LOG=/tmp/zicada-smoke.log

# Tool preflight: each AE relies on one of these, so a missing tool needs
# to fail loudly at the top, not halfway through AE4.
for tool in zig redis-cli redis-server dig curl python3 nc; do
    command -v "$tool" >/dev/null || { red "missing tool: $tool"; exit 1; }
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

step() { printf '\n'; bold "== $1 =="; }

dump_log() {
    if [ -f "$LOG" ]; then
        echo "--- last 40 lines of $LOG ---"
        tail -n 40 "$LOG" || true
        echo "--- end ---"
    fi
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        red "FAIL: expected: $2"
        red "      actual:   $1"
        dump_log
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
step "build zicada"
( cd "$ROOT" && zig build )

if [ ! -x "$BIN" ]; then
    red "binary missing: $BIN"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Redis lifecycle
# ---------------------------------------------------------------------------
step "redis: ensure running"
if ! redis-cli -u "$DSN" ping >/dev/null 2>&1; then
    echo "starting redis-server on 6379"
    redis-server --daemonize yes --port 6379 --save "" --appendonly no
    for _ in $(seq 1 20); do
        if redis-cli -u "$DSN" ping >/dev/null 2>&1; then break; fi
        sleep 0.1
    done
fi
redis-cli -u "$DSN" ping
# Clear any state left over from a prior interrupted run, so AE1/AE3/AE4
# start from a known-empty Redis (AE2's key is also wiped on its own way).
redis-cli -u "$DSN" DEL "dns-a-$NAME" "dns-a-smoke-http.example.com" >/dev/null

cleanup() {
    bold "== teardown: stop zicada =="
    if [ -n "${ZICADA_PID:-}" ] && kill -0 "$ZICADA_PID" 2>/dev/null; then
        kill -TERM "$ZICADA_PID" 2>/dev/null || true
        # Bound the wait so a stuck server cannot hang the harness; escalate
        # to SIGKILL if SIGTERM didn't take within ~2s.
        for _ in $(seq 1 20); do
            kill -0 "$ZICADA_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$ZICADA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 3. Start server
# ---------------------------------------------------------------------------
step "start zicada -serv on port $PORT"
"$BIN" -serv -port "$PORT" -dsn "$DSN" >"$LOG" 2>&1 &
ZICADA_PID=$!

# Wait for the UDP listener to bind AND confirm zicada is still alive.
# Server log is at $LOG; dig . probes root, which v1 servers don't answer
# (returns silently), so use TCP-connect via nc -z against the HTTP port
# ($PORT + 1) instead — that's a positive, immediate signal.
bound=0
for _ in $(seq 1 30); do
    if ! kill -0 "$ZICADA_PID" 2>/dev/null; then
        red "zicada died on startup — see $LOG"
        dump_log
        exit 1
    fi
    if nc -z 127.0.0.1 "$((PORT+1))" 2>/dev/null; then
        bound=1; break
    fi
    sleep 0.1
done
if [ "$bound" -ne 1 ]; then
    red "zicada never bound :$PORT within ~3s — see $LOG"
    dump_log
    exit 1
fi

# ---------------------------------------------------------------------------
# AE1: CLI add writes Redis correctly
# ---------------------------------------------------------------------------
step "AE1: CLI add writes zone-text A to Redis"
"$BIN" -name "$NAME" -ip 10.0.0.1 -ttl "$TTL"
val=$(redis-cli -u "$DSN" GET "dns-a-$NAME")
assert_eq "$val" "$NAME. $TTL IN A 10.0.0.1"
green "AE1 ok: redis has $val"

# ---------------------------------------------------------------------------
# AE3: dig query returns the inserted record
# ---------------------------------------------------------------------------
step "AE3: dig A query returns the record"
ans=$(dig @127.0.0.1 -p "$PORT" +tries=1 +time=2 "$NAME" A +short)
assert_eq "$ans" "10.0.0.1"
green "AE3 ok: dig returned $ans"

# ---------------------------------------------------------------------------
# AE2: HTTP PUT /api/dns/a returns ok
# ---------------------------------------------------------------------------
step "AE2: HTTP PUT returns ok"
put_body='[{"name":"smoke-http.example.com","ip":"10.0.0.7"}]'
put_resp=$(curl -sS -X PUT --data "$put_body" "http://127.0.0.1:$((PORT+1))/api/dns/a")
assert_eq "$put_resp" "ok"
http_val=$(redis-cli -u "$DSN" GET "dns-a-smoke-http.example.com")
assert_eq "$http_val" "smoke-http.example.com. $TTL IN A 10.0.0.7"
# Round-trip the PUT through DNS so AE2 covers the full HTTP→Redis→query
# path, not just "PUT writes Redis".
http_ans=$(dig @127.0.0.1 -p "$PORT" +tries=1 +time=2 smoke-http.example.com A +short)
assert_eq "$http_ans" "10.0.0.7"
green "AE2 ok: PUT returned ok, redis and dig both see the record"

# ---------------------------------------------------------------------------
# AE4: UPDATE via UDP changes the A record and dig reflects the new value
# ---------------------------------------------------------------------------
# nsupdate uses TCP by default for UPDATE messages (RFC 2136 §3.1) and the v1
# server is UDP-only (TCP is deferred — see plan scope boundaries), so we
# serialize the UPDATE ourselves and send it as a raw UDP datagram. This still
# exercises the U6 UPDATE handler end-to-end against the running server.
step "AE4: UPDATE via UDP changes the A record"
python3 - "$PORT" "$NAME" "$TTL" <<'PYEOF'
import socket, struct, sys
port = int(sys.argv[1]); name = sys.argv[2]; ttl = int(sys.argv[3])
def enc_name(n):
    parts = []
    for lbl in n.rstrip('.').split('.'):
        b = lbl.encode()
        if not (1 <= len(b) <= 63):
            sys.exit(f"label {lbl!r} has bad length {len(b)}")
        parts.append(bytes([len(b)]) + b)
    parts.append(b'\x00')
    return b''.join(parts)
zone_name = enc_name('example.com')
upd_name = enc_name(name)
# Header: ID=0xCAFE, FLAGS=0x2800 (QR=0, OPCODE=5), QD=1, AN=0, NS=1, AR=0.
header = struct.pack('>HHHHHH', 0xCAFE, 0x2800, 1, 0, 1, 0)
zone_q = struct.pack('>HH', 6, 1)  # QTYPE=SOA, QCLASS=IN
upd_rr = struct.pack('>HHIH', 1, 1, ttl, 4) + bytes([10, 0, 0, 99])
msg = header + zone_name + zone_q + upd_name + upd_rr
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
s.sendto(msg, ('127.0.0.1', port))
data, _ = s.recvfrom(512)
qr = (data[2] >> 7) & 1
opcode = (data[2] >> 3) & 0x0f
rcode = data[3] & 0x0f
if (qr, opcode, rcode) != (1, 5, 0):
    sys.exit(f"UPDATE got QR={qr} OPCODE={opcode} RCODE={rcode}, response={data.hex()}")
PYEOF
ans=$(dig @127.0.0.1 -p "$PORT" +tries=1 +time=2 "$NAME" A +short)
assert_eq "$ans" "10.0.0.99"
green "AE4 ok: post-UPDATE dig returned $ans"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
green "ALL PASS"