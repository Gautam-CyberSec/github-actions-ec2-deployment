#!/usr/bin/env bash
# Unit tests for deploy/lib.sh.
#
# No SSH, no Docker, no AWS, no network. The deployment logic most likely to be
# wrong — which colour is chosen, which port it maps to, whether a health
# response actually proves the new build is running — is exercised directly.
set -uo pipefail

# shellcheck source-path=SCRIPTDIR/..
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib.sh
source "$HERE/../deploy/lib.sh"

PASS=0
FAIL=0

check() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n       want: %q\n       got:  %q\n' "$name" "$want" "$got"
    fi
}

status_of() {
    if "$@" >/dev/null 2>&1; then printf 'ok'; else printf 'err'; fi
}

# ── colour selection ─────────────────────────────────────────────────────────

check "blue deploys to green" "green" "$(next_color blue)"
check "green deploys to blue" "blue" "$(next_color green)"
check "no current colour starts at blue" "blue" "$(next_color '')"
check "an unrecognised colour starts at blue" "blue" "$(next_color banana)"

# The property that matters: a deploy never targets the colour serving traffic.
for c in blue green '' garbage; do
    got="$(next_color "$c")"
    if [[ "$got" == "$c" ]]; then
        check "never deploys over the live colour ($c)" "different" "same"
    else
        check "never deploys over the live colour (${c:-none})" "different" "different"
    fi
done

# ── ports ────────────────────────────────────────────────────────────────────

check "blue maps to 3001" "3001" "$(port_for_color blue)"
check "green maps to 3002" "3002" "$(port_for_color green)"
check "an unknown colour has no port" "err" "$(status_of port_for_color purple)"
check "the two colours cannot share a port" "different" \
    "$([[ "$(port_for_color blue)" != "$(port_for_color green)" ]] && echo different || echo same)"

# ── naming ───────────────────────────────────────────────────────────────────

check "container name combines app and colour" "api-blue" "$(container_name api blue)"

# ── image references ─────────────────────────────────────────────────────────

check "builds a fully qualified reference" "ghcr.io/acme/api:sha-abc123" \
    "$(image_ref ghcr.io acme/api sha-abc123)"

# A mutable tag makes both verification and rollback meaningless: the tag a
# deploy records can point at different bytes later.
check "refuses the latest tag" "err" "$(status_of image_ref ghcr.io acme/api latest)"
check "accepts an immutable tag" "ok" "$(status_of image_ref ghcr.io acme/api v1.2.3)"

# ── nginx upstream ───────────────────────────────────────────────────────────

up="$(render_upstream green)"
check "upstream points at the green port" "1" "$(printf '%s' "$up" | grep -c '127.0.0.1:3002')"
check "upstream records the active colour" "1" "$(printf '%s' "$up" | grep -c 'Active colour: green')"
check "upstream declares an upstream block" "1" "$(printf '%s' "$up" | grep -c '^upstream app {')"
check "rendering an unknown colour fails" "err" "$(status_of render_upstream mauve)"

# The deploy reads the active colour back out of this file, so the marker it
# writes and the pattern it greps for have to agree. Testing them together is
# what stops a formatting change silently breaking colour detection.
for colour in blue green; do
    rendered="$(render_upstream "$colour")"
    parsed="$(printf '%s' "$rendered" | grep -oE 'Active colour: (blue|green)' | awk '{print $3}')"
    check "the rendered marker is readable back ($colour)" "$colour" "$parsed"
done

# ── health verification ──────────────────────────────────────────────────────

ok_body='{"status":"ok","version":"sha-abc123","color":"green","uptime_s":3}'
check "accepts a healthy response for the expected build" "ok" \
    "$(status_of health_is_ok "$ok_body" sha-abc123)"

# The important one: healthy but still running the previous build is a failed
# deployment, not a successful one.
check "rejects a healthy response running the wrong version" "err" \
    "$(status_of health_is_ok "$ok_body" sha-def456)"

check "rejects an unhealthy response" "err" \
    "$(status_of health_is_ok '{"status":"degraded","version":"sha-abc123"}' sha-abc123)"
check "rejects an empty body" "err" "$(status_of health_is_ok '' sha-abc123)"
check "accepts any version when none is expected" "ok" \
    "$(status_of health_is_ok "$ok_body" '')"

# ── remote command construction ──────────────────────────────────────────────

cmd="$(remote_docker_run ghcr.io/acme/api:sha-1 api-blue 3001 blue sha-1)"
check "removes any container of the same name first" "1" "$(printf '%s' "$cmd" | grep -c 'docker rm -f api-blue')"
check "publishes only on loopback" "1" "$(printf '%s' "$cmd" | grep -c '127.0.0.1:3001:3000')"
check "runs with a read-only root filesystem" "1" "$(printf '%s' "$cmd" | grep -c -- '--read-only')"
check "blocks privilege escalation" "1" "$(printf '%s' "$cmd" | grep -c 'no-new-privileges:true')"
check "passes the version to the container" "1" "$(printf '%s' "$cmd" | grep -c 'APP_VERSION=sha-1')"
check "restarts unless stopped" "1" "$(printf '%s' "$cmd" | grep -c -- '--restart unless-stopped')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
