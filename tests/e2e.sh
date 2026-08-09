#!/usr/bin/env bash
#
# End-to-end deployment test.
#
# Runs deploy/deploy.sh — the same script production uses — against a real SSH
# host with real Docker and real nginx. In CI that host is the runner itself,
# reached over loopback SSH; in production it is an EC2 instance. The script
# cannot tell the difference, which is the point: the deployment path is
# exercised without needing an AWS account.
#
# What this does NOT prove: anything specific to EC2 — instance profiles,
# security groups, IMDS. Those are unverified here and SECURITY.md says so.
#
#   sudo ./tests/e2e.sh          (CI; needs docker, nginx, sshd on localhost)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

APP="${APP_NAME:-deploy-payload}"
HOST="${E2E_HOST:-127.0.0.1}"
USER_NAME="${E2E_USER:-$(id -un)}"
KEY="${E2E_KEY:?E2E_KEY must point at the private key}"
KNOWN_HOSTS="${E2E_KNOWN_HOSTS:?E2E_KNOWN_HOSTS must point at a known_hosts file}"
UPSTREAM="${NGINX_UPSTREAM_PATH:-/etc/nginx/conf.d/upstream.conf}"
REPO="${IMAGE_REPO:?IMAGE_REPO required}"
REGISTRY="${REGISTRY:-ghcr.io}"

# Three immutable tags, built and pushed by the workflow before this runs.
V1="${E2E_TAG_1:?E2E_TAG_1 required}"
V2="${E2E_TAG_2:?E2E_TAG_2 required}"
V3="${E2E_TAG_3:?E2E_TAG_3 required}"

PASS=0
FAIL=0

check() {
    local desc="$1" status="$2" detail="${3:-}"
    if [[ "$status" -eq 0 ]]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$desc"
        [[ -n "$detail" ]] && printf '       %s\n' "$detail"
    fi
    return 0
}

deploy() {
    "$ROOT/deploy/deploy.sh" \
        --host "$HOST" --user "$USER_NAME" \
        --key "$KEY" --known-hosts "$KNOWN_HOSTS" \
        --repo "$REPO" --tag "$1"
}

active_color() {
    grep -oE 'Active colour: (blue|green)' "$UPSTREAM" 2>/dev/null | awk '{print $3}'
}

serving_version() {
    curl -fsS --max-time 5 http://127.0.0.1/version 2>/dev/null
}

printf '\n== environment ==\n'
printf '  %s\n' "$(docker --version)"
printf '  %s\n' "$(nginx -v 2>&1)"
printf '  host: %s@%s\n' "$USER_NAME" "$HOST"

# ── first deploy ─────────────────────────────────────────────────────────────

printf '\n== first deploy (no previous colour) ==\n'
out="$(deploy "$V1" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
check "first deploy succeeds" "$rc"

if [[ "$(active_color)" == "blue" ]]; then s=0; else s=1; fi
check "first deploy lands on blue (got $(active_color))" "$s"

printf '%s' "$(serving_version)" | grep -q "\"version\":\"$V1\""
s=$?
check "proxy serves $V1" "$s" "$(serving_version)"

# ── second deploy alternates colour ──────────────────────────────────────────

printf '\n== second deploy (must alternate) ==\n'
out="$(deploy "$V2" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
check "second deploy succeeds" "$rc"

if [[ "$(active_color)" == "green" ]]; then s=0; else s=1; fi
check "second deploy lands on green (got $(active_color))" "$s"

printf '%s' "$(serving_version)" | grep -q "\"version\":\"$V2\""
s=$?
check "proxy now serves $V2" "$s" "$(serving_version)"

# The old container is stopped, not removed, so a rollback is a start rather
# than a pull.
docker ps -a --format '{{.Names}}' | grep -q "${APP}-blue"
s=$?
check "previous colour is retained for rollback" "$s"

if [[ "$(docker inspect -f '{{.State.Running}}' "${APP}-blue" 2>/dev/null)" == "false" ]]; then s=0; else s=1; fi
check "previous colour is stopped, not serving" "$s"

# ── zero downtime across the switch ──────────────────────────────────────────

printf '\n== zero downtime ==\n'
ERRORS_FILE="$(mktemp)"
(
    end=$((SECONDS + 25))
    while [[ $SECONDS -lt $end ]]; do
        curl -fsS --max-time 2 -o /dev/null http://127.0.0.1/healthz 2>/dev/null || echo x >>"$ERRORS_FILE"
        sleep 0.1
    done
) &
POLLER=$!
sleep 2
deploy "$V3" >/dev/null 2>&1
dep_rc=$?
wait "$POLLER" 2>/dev/null || true

errors="$(wc -l <"$ERRORS_FILE" | tr -d ' ')"
rm -f "$ERRORS_FILE"
check "deploy during continuous traffic succeeds" "$dep_rc"
if [[ "$errors" -eq 0 ]]; then s=0; else s=1; fi
check "no failed requests across the switch (${errors} failed)" "$s"

# ── failed health check must not switch traffic ──────────────────────────────

printf '\n== a broken build must not take traffic ==\n'
before_color="$(active_color)"
before_version="$(serving_version)"

# A tag that was never pushed: the pull fails, so the deploy must abort before
# touching the upstream.
if deploy "sha-does-not-exist" >/dev/null 2>&1; then s=1; else s=0; fi
check "deploy of a missing image fails" "$s"

if [[ "$(active_color)" == "$before_color" ]]; then s=0; else s=1; fi
check "upstream unchanged after a failed deploy (still $before_color)" "$s"

if [[ "$(serving_version)" == "$before_version" ]]; then s=0; else s=1; fi
check "traffic still served by the previous build" "$s" "$(serving_version)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
