#!/usr/bin/env bash
# scripts/smoke.sh — full end-to-end smoke for zicada.
#
# Brings up Redis, builds the binary, and exercises AE1-AE4:
#   AE1: CLI add writes Redis
#   AE2: HTTP PUT /api/dns/a returns ok
#   AE3: dig A query returns the inserted record
#   AE4: nsupdate changes the record and dig reflects the new value
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

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

step() { printf '\n'; bold "== $1 =="; }

assert_eq() {
    if [ "$1" != "$2" ]; then
        red "FAIL: expected: $2"
        red "      actual:   $1"
        exit 1
    fi
}

assert_contains() {
    if ! printf '%s' "$1" | grep -qF "$2"; then
        red "FAIL: '$1' does not contain '$2'"
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
redis-cli -u "$DSN" DEL "dns-a-$NAME" >/dev/null

cleanup() {
    step "teardown: stop zicada"
    if [ -n "${ZICADA_PID:-}" ] && kill -0 "$ZICADA_PID" 2>/dev/null; then
        kill -TERM "$ZICADA_PID" 2>/dev/null || true
        wait "$ZICADA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Start server
# ---------------------------------------------------------------------------
step "start zicada -serv on port $PORT"
"$BIN" -serv -port "$PORT" -dsn "$DSN" >/tmp/zicada-smoke.log 2>&1 &
ZICADA_PID=$!

# Wait for the UDP listener to bind.
for _ in $(seq 1 30); do
    if dig @127.0.0.1 -p "$PORT" +timeout=1 +tries=1 . >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

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
ans=$(dig @127.0.0.1 -p "$PORT" "$NAME" A +short)
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
green "AE2 ok: PUT returned ok and redis has the record"

# ---------------------------------------------------------------------------
# AE4: UPDATE via UDP changes the A record and dig reflects the new value
# ---------------------------------------------------------------------------
# nsupdate uses TCP by default for UPDATE messages (RFC 2136 §3.1) and the v1
# server is UDP-only (TCP is deferred — see plan scope boundaries), so we
# serialize the UPDATE ourselves and send it as a raw UDP datagram. This still
# exercises the U6 UPDATE handler end-to-end against the running server.
step "AE4: UPDATE via UDP changes the A record"
python3 - "$PORT" "$NAME" "$TTL" <<'PYEOF' >/dev/null
import socket, struct, sys
port = int(sys.argv[1]); name = sys.argv[2]; ttl = int(sys.argv[3])
def enc_name(n):
    parts = []
    for lbl in n.rstrip('.').split('.'):
        b = lbl.encode()
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
rcode = data[3] & 0x0f
if rcode != 0:
    sys.exit(f"UPDATE got RCODE={rcode}, response={data.hex()}")
PYEOF
ans=$(dig @127.0.0.1 -p "$PORT" "$NAME" A +short)
assert_eq "$ans" "10.0.0.99"
green "AE4 ok: post-UPDATE dig returned $ans"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
green "ALL PASS"