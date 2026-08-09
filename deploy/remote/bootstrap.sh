#!/usr/bin/env bash
#
# One-time preparation of a deployment host (an EC2 instance in production).
# Run once, as a sudo-capable user, before the first deploy.
#
#   sudo ./bootstrap.sh --deploy-user deploy --pubkey "ssh-ed25519 AAAA..."
#
# Creates the deployment user, installs Docker and nginx, and grants exactly the
# sudo rights deploy.sh needs — nginx and mv, nothing else. A deployment account
# with full sudo is a deployment account that can do anything.
set -uo pipefail

DEPLOY_USER="deploy"
PUBKEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy-user)
            DEPLOY_USER="${2:?}"
            shift
            ;;
        --pubkey)
            PUBKEY="${2:?}"
            shift
            ;;
        -h | --help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || {
    printf 'must run as root\n' >&2
    exit 1
}
[[ -n "$PUBKEY" ]] || {
    printf -- '--pubkey is required\n' >&2
    exit 1
}

log() { printf '  %s\n' "$*"; }

log "installing docker and nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io nginx curl

log "creating ${DEPLOY_USER}"
id -u "$DEPLOY_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"

install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
printf '%s\n' "$PUBKEY" >"/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 0600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

# Exactly two commands, not blanket sudo. deploy.sh needs to move the rendered
# upstream into place and reload nginx; it needs nothing else, so it gets
# nothing else.
log "granting scoped sudo (nginx, mv only)"
cat >"/etc/sudoers.d/${DEPLOY_USER}-deploy" <<SUDOERS
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/sbin/nginx, /bin/mv
SUDOERS
chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}-deploy"
visudo -cf "/etc/sudoers.d/${DEPLOY_USER}-deploy" >/dev/null || {
    rm -f "/etc/sudoers.d/${DEPLOY_USER}-deploy"
    printf 'sudoers validation failed — nothing granted\n' >&2
    exit 1
}

log "installing the nginx proxy"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${HERE}/../nginx/app.conf" /etc/nginx/conf.d/app.conf
[[ -f /etc/nginx/conf.d/upstream.conf ]] ||
    cp "${HERE}/../nginx/upstream.conf.initial" /etc/nginx/conf.d/upstream.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

log "done — the host is ready for deploy.sh"
log "SSH must be key-only; see Linux-Server-Hardening for that baseline"
