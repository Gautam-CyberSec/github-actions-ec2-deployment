#!/usr/bin/env bash
#
# Blue/green deployment to a single Docker host over SSH.
#
# Deploys to the colour that is NOT currently serving, health-checks it against
# the expected build, switches the nginx upstream, and only then stops the old
# container. Any failure before the switch leaves the live container untouched;
# any failure after it rolls the upstream back.
#
#   ./deploy/deploy.sh --host 1.2.3.4 --tag sha-abc123
#
# The host is addressed generically on purpose: production points at EC2, and CI
# points at an SSH target it controls, so the same script is exercised either way.
set -uo pipefail

# shellcheck source-path=SCRIPTDIR
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib.sh
source "$HERE/lib.sh"

APP="${APP_NAME:-deploy-payload}"
REGISTRY="${REGISTRY:-ghcr.io}"
REPO="${IMAGE_REPO:-}"
TAG=""
HOST=""
USER_NAME="${DEPLOY_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"
KEY_FILE="${SSH_KEY_FILE:-}"
KNOWN_HOSTS="${SSH_KNOWN_HOSTS_FILE:-}"
NGINX_UPSTREAM="${NGINX_UPSTREAM_PATH:-/etc/nginx/conf.d/upstream.conf}"
HEALTH_RETRIES="${HEALTH_RETRIES:-15}"
HEALTH_DELAY="${HEALTH_DELAY:-2}"
DRY_RUN=0

log() { printf '  %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
fail() {
    printf '\n  FAILED: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
deploy.sh — blue/green deployment to a Docker host over SSH

  --host HOST        target hostname or IP           (required)
  --tag TAG          immutable image tag to deploy   (required)
  --repo REPO        registry repository, e.g. owner/app
  --user USER        SSH user                        (default: deploy)
  --port PORT        SSH port                        (default: 22)
  --key FILE         SSH private key file
  --known-hosts FILE known_hosts for host verification
  --dry-run          print the plan and exit
  -h, --help

Every value can also come from the environment; see README.md.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST="${2:-}"
            shift
            ;;
        --tag)
            TAG="${2:-}"
            shift
            ;;
        --repo)
            REPO="${2:-}"
            shift
            ;;
        --user)
            USER_NAME="${2:-}"
            shift
            ;;
        --port)
            SSH_PORT="${2:-}"
            shift
            ;;
        --key)
            KEY_FILE="${2:-}"
            shift
            ;;
        --known-hosts)
            KNOWN_HOSTS="${2:-}"
            shift
            ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

[[ -n "$HOST" ]] || fail "--host is required"
[[ -n "$TAG" ]] || fail "--tag is required"
[[ -n "$REPO" ]] || fail "--repo or IMAGE_REPO is required"

IMAGE="$(image_ref "$REGISTRY" "$REPO" "$TAG")" || fail "invalid image reference"

# ── SSH ──────────────────────────────────────────────────────────────────────

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -p "$SSH_PORT")

if [[ -n "$KNOWN_HOSTS" ]]; then
    # Host key verification is the difference between deploying to your server
    # and deploying to whoever answers. StrictHostKeyChecking=no would make this
    # script work everywhere and authenticate nothing.
    SSH_OPTS+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS")
else
    log "WARNING: no known_hosts supplied — host identity will not be verified"
    SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
fi

[[ -n "$KEY_FILE" ]] && SSH_OPTS+=(-i "$KEY_FILE")

# Arguments are expanded locally and the resulting string is sent to the remote
# shell. That is intended: commands are assembled here, by lib.sh, where the
# quoting is testable — rather than being composed remotely where it is not.
# shellcheck disable=SC2029
remote() {
    ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" "$@"
}

# ── plan ─────────────────────────────────────────────────────────────────────

step "Plan"
log "host        ${USER_NAME}@${HOST}:${SSH_PORT}"
log "image       ${IMAGE}"
log "upstream    ${NGINX_UPSTREAM}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry run — nothing was contacted"
    exit 0
fi

remote true || fail "cannot reach ${USER_NAME}@${HOST} over SSH"
log "ssh         reachable"

# The colour currently serving is read from the host rather than assumed, so a
# deploy that ran from someone else's laptop is still accounted for.
CURRENT="$(remote "grep -oE 'Active colour: (blue|green)' ${NGINX_UPSTREAM} 2>/dev/null | awk '{print \$3}'" || true)"
CURRENT="$(printf '%s' "$CURRENT" | tr -d '[:space:]')"
TARGET="$(next_color "$CURRENT")"
TARGET_PORT="$(port_for_color "$TARGET")"
TARGET_NAME="$(container_name "$APP" "$TARGET")"

log "current     ${CURRENT:-none}"
log "deploying   ${TARGET} on port ${TARGET_PORT}"

# ── pull and start the inactive colour ───────────────────────────────────────

step "Pull"
remote "docker pull ${IMAGE}" >/dev/null || fail "could not pull ${IMAGE}"
log "pulled ${IMAGE}"

step "Start ${TARGET}"
remote "$(remote_docker_run "$IMAGE" "$TARGET_NAME" "$TARGET_PORT" "$TARGET" "$TAG")" >/dev/null ||
    fail "could not start ${TARGET_NAME}"
log "started ${TARGET_NAME}"

# ── verify before switching ──────────────────────────────────────────────────

step "Health check"
healthy=0
for attempt in $(seq 1 "$HEALTH_RETRIES"); do
    body="$(remote "curl -fsS --max-time 3 http://127.0.0.1:${TARGET_PORT}/healthz" 2>/dev/null || true)"
    if health_is_ok "$body" "$TAG"; then
        log "healthy after ${attempt} attempt(s): ${body}"
        healthy=1
        break
    fi
    sleep "$HEALTH_DELAY"
done

if [[ "$healthy" -ne 1 ]]; then
    # Nothing has been switched yet, so the live container is still serving.
    # Remove the failed one and leave the host exactly as it was.
    log "never became healthy — removing ${TARGET_NAME}, live traffic untouched"
    remote "docker rm -f ${TARGET_NAME}" >/dev/null 2>&1 || true
    fail "health check failed for ${IMAGE}"
fi

# ── switch traffic ───────────────────────────────────────────────────────────

step "Switch traffic to ${TARGET}"
UPSTREAM="$(render_upstream "$TARGET")"

# Written to a temp file and moved into place, so nginx can never read a
# half-written upstream. Validated before reload, because a bad config that gets
# reloaded takes the site down.
remote "cat > /tmp/upstream.conf <<'UPSTREAM_EOF'
${UPSTREAM}
UPSTREAM_EOF
sudo mv /tmp/upstream.conf ${NGINX_UPSTREAM} && sudo nginx -t" >/dev/null || {
    log "nginx rejected the new upstream — rolling back"
    remote "docker rm -f ${TARGET_NAME}" >/dev/null 2>&1 || true
    fail "nginx configuration test failed"
}

# reload, not restart: existing connections drain rather than being cut.
remote "sudo nginx -s reload" >/dev/null || fail "nginx reload failed"
log "upstream now points at ${TARGET}"

# ── verify through the proxy, and roll back if it is wrong ───────────────────

step "Verify through the proxy"
body="$(remote "curl -fsS --max-time 5 http://127.0.0.1/healthz" 2>/dev/null || true)"
if ! health_is_ok "$body" "$TAG"; then
    log "proxy is not serving ${TAG} — rolling the upstream back to ${CURRENT:-previous}"
    if [[ -n "$CURRENT" ]]; then
        remote "cat > /tmp/upstream.conf <<'UPSTREAM_EOF'
$(render_upstream "$CURRENT")
UPSTREAM_EOF
sudo mv /tmp/upstream.conf ${NGINX_UPSTREAM} && sudo nginx -t && sudo nginx -s reload" >/dev/null || true
    fi
    remote "docker rm -f ${TARGET_NAME}" >/dev/null 2>&1 || true
    fail "post-switch verification failed"
fi
log "serving ${body}"

# ── retire the old colour ────────────────────────────────────────────────────

step "Retire ${CURRENT:-none}"
if [[ -n "$CURRENT" && "$CURRENT" != "$TARGET" ]]; then
    OLD_NAME="$(container_name "$APP" "$CURRENT")"
    # Stopped rather than removed: rollback to the previous build is then a
    # container start instead of an image pull, which matters when the registry
    # is the thing that broke.
    remote "docker stop ${OLD_NAME}" >/dev/null 2>&1 || true
    log "stopped ${OLD_NAME} — kept for rollback"
else
    log "nothing to retire"
fi

step "Deployed"
log "${IMAGE} is live on ${TARGET}"
