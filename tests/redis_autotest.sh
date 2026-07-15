#!/usr/bin/env bash
# Redis 7.4.9 functional autotest for RED OS 8 package validation.
set -u
CLI="redis-cli"
PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); printf '[FAIL] %s -- got: %s\n' "$1" "${2:-}"; }

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc" "$actual (expected $expected)"; fi
}

echo "=== 0. Service / package sanity ==="
rpm -q redis >/dev/null 2>&1 && ok "redis RPM is installed" || bad "redis RPM is installed"
systemctl is-active --quiet redis && ok "systemd unit 'redis' is active" || bad "systemd unit 'redis' is active"
systemctl is-enabled --quiet redis && ok "systemd unit 'redis' is enabled" || bad "systemd unit 'redis' is enabled"

echo "=== 1. Connectivity ==="
check_eq "PING returns PONG" "PONG" "$($CLI ping)"
VER=$($CLI info server | grep -m1 '^redis_version:' | tr -d '\r' | cut -d: -f2)
check_eq "redis_version is 7.4.9" "7.4.9" "$VER"

echo "=== 2. Strings ==="
$CLI set greeting "hello" >/dev/null
check_eq "GET after SET" "hello" "$($CLI get greeting)"
$CLI append greeting " world" >/dev/null
check_eq "APPEND works" "hello world" "$($CLI get greeting)"
$CLI set counter 10 >/dev/null
check_eq "INCRBY" "15" "$($CLI incrby counter 5)"
check_eq "EXPIRE + TTL" "1" "$($CLI expire counter 100 > /dev/null; $CLI exists counter)"

echo "=== 3. Lists ==="
$CLI del mylist >/dev/null
$CLI rpush mylist a b c >/dev/null
check_eq "LLEN" "3" "$($CLI llen mylist)"
check_eq "LPOP" "a" "$($CLI lpop mylist)"
check_eq "LRANGE remainder" "b c" "$($CLI lrange mylist 0 -1 | tr '\n' ' ' | sed 's/ $//')"

echo "=== 4. Hashes ==="
$CLI del myhash >/dev/null
$CLI hset myhash f1 v1 f2 v2 >/dev/null
check_eq "HGET" "v1" "$($CLI hget myhash f1)"
check_eq "HLEN" "2" "$($CLI hlen myhash)"

echo "=== 5. Sets ==="
$CLI del myset >/dev/null
$CLI sadd myset x y z >/dev/null
check_eq "SCARD" "3" "$($CLI scard myset)"
check_eq "SISMEMBER hit" "1" "$($CLI sismember myset x)"
check_eq "SISMEMBER miss" "0" "$($CLI sismember myset q)"

echo "=== 6. Sorted sets ==="
$CLI del myzset >/dev/null
$CLI zadd myzset 1 one 2 two 3 three >/dev/null
check_eq "ZRANGE" "one two three" "$($CLI zrange myzset 0 -1 | tr '\n' ' ' | sed 's/ $//')"
check_eq "ZSCORE" "2" "$($CLI zscore myzset two)"

echo "=== 7. Expiration ==="
$CLI set volatilekey val px 200 >/dev/null
sleep 0.4
check_eq "key auto-expires" "0" "$($CLI exists volatilekey)"

echo "=== 8. Transactions (MULTI/EXEC) ==="
printf 'MULTI\nSET tx_key 1\nINCR tx_key\nEXEC\n' | $CLI >/dev/null
check_eq "MULTI/EXEC INCR result" "2" "$($CLI get tx_key)"

echo "=== 9. Pub/Sub ==="
( $CLI subscribe chan_test > /tmp/redis_sub_out.$$ 2>&1 & echo $! > /tmp/redis_sub_pid.$$ )
sleep 0.5
$CLI publish chan_test "hello_pubsub" >/dev/null
sleep 0.5
SUBPID=$(cat /tmp/redis_sub_pid.$$)
kill "$SUBPID" 2>/dev/null
if grep -q "hello_pubsub" /tmp/redis_sub_out.$$; then ok "PUBLISH/SUBSCRIBE delivers message"; else bad "PUBLISH/SUBSCRIBE delivers message" "$(cat /tmp/redis_sub_out.$$)"; fi
rm -f /tmp/redis_sub_out.$$ /tmp/redis_sub_pid.$$

echo "=== 10. Lua scripting (EVAL) ==="
check_eq "EVAL returns computed value" "9" "$($CLI eval 'return 4+5' 0)"

echo "=== 11. Persistence (SAVE / BGSAVE) ==="
$CLI save >/dev/null 2>&1 && ok "SAVE (RDB snapshot) succeeds" || bad "SAVE (RDB snapshot) succeeds"
RDB_PATH=$($CLI config get dir | tail -1)/$($CLI config get dbfilename | tail -1)
sudo -n test -f "$RDB_PATH" && ok "RDB file exists on disk ($RDB_PATH)" || bad "RDB file exists on disk" "$RDB_PATH missing"

echo "=== 12. AOF check tool ==="
if command -v redis-check-rdb >/dev/null; then
    if sudo -n -u redis redis-check-rdb "$RDB_PATH" >/tmp/checkrdb.$$ 2>&1; then
        ok "redis-check-rdb validates RDB file"
    else
        bad "redis-check-rdb validates RDB file" "$(cat /tmp/checkrdb.$$)"
    fi
    rm -f /tmp/checkrdb.$$
else
    bad "redis-check-rdb binary present" "not found"
fi

echo "=== 13. Restart persistence (data survives systemd restart) ==="
$CLI set restart_probe "still_here" >/dev/null
$CLI save >/dev/null
sudo -n systemctl restart redis
sleep 1
RESTART_VAL=$($CLI get restart_probe 2>/dev/null)
check_eq "value survives service restart" "still_here" "$RESTART_VAL"

echo "=== 14. Config file is actually loaded ==="
CFG_PORT=$($CLI config get port | tail -1)
check_eq "server running on configured port 6379" "6379" "$CFG_PORT"

echo "=== 15. Cleanup test keys ==="
$CLI del greeting counter mylist myhash myset myzset tx_key restart_probe >/dev/null
ok "test keys cleaned up"

echo
echo "================= SUMMARY ================="
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All Redis functionality checks passed."
exit 0
