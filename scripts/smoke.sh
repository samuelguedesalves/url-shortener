#!/usr/bin/env bash
# End-to-end smoke test: create a link, follow it, check the headers and the error cases.
# Needs the stack running (docker compose up -d) and curl + jq installed.
set -euo pipefail

WRITE_API="${WRITE_API_URL:-http://localhost:4001}"
REDIRECT_API="${REDIRECT_API_URL:-http://localhost:4002}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "waiting for services..."
for i in $(seq 1 60); do
  curl -sf "$WRITE_API/health" >/dev/null && curl -sf "$REDIRECT_API/health" >/dev/null && break
  [ "$i" -eq 60 ] && fail "services did not become healthy"
  sleep 2
done

echo "creating a link..."
body=$(curl -sf -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d '{"url":"https://example.com/smoke"}') || fail "POST /urls failed"
code=$(echo "$body" | jq -r .code)
[[ "$code" =~ ^[0-9A-Za-z]{7}$ ]] || fail "unexpected code: $code"

echo "following /$code..."
headers=$(curl -s -o /dev/null -D - "$REDIRECT_API/$code")
echo "$headers" | head -1 | grep -q ' 302' || fail "expected 302, got: $(echo "$headers" | head -1)"
echo "$headers" | grep -qi '^location: https://example.com/smoke' || fail "wrong Location"
echo "$headers" | grep -qi '^cache-control: no-store' || fail "missing Cache-Control: no-store"

echo "custom alias, then a clash..."
alias_name="smoke-$(date +%s)"
curl -sf -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d "{\"url\":\"https://example.com/a\",\"custom_alias\":\"$alias_name\"}" >/dev/null || fail "alias create failed"
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d "{\"url\":\"https://example.com/b\",\"custom_alias\":\"$alias_name\"}")
[ "$status" = "409" ] || fail "expected 409 for a taken alias, got $status"

echo "unknown code..."
status=$(curl -s -o /dev/null -w '%{http_code}' "$REDIRECT_API/doesnotexist")
[ "$status" = "404" ] || fail "expected 404, got $status"

echo "expired link..."
curl -sf -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d '{"url":"https://example.com/short","custom_alias":"short-'"$alias_name"'","ttl_seconds":1}' >/dev/null || fail "short ttl create failed"
sleep 2
status=$(curl -s -o /dev/null -w '%{http_code}' "$REDIRECT_API/short-$alias_name")
[ "$status" = "410" ] || fail "expected 410 for an expired link, got $status"

echo "OK"
