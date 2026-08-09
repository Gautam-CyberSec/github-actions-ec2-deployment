# syntax=docker/dockerfile:1
#
# The runtime is built from a bare Alpine with the node binary copied in, rather
# than FROM node:22-alpine directly.
#
# This pattern is established in docker-node-postgres-stack and is applied here
# rather than merely referenced: the first build of this image shipped npm and
# failed its Trivy gate with the same findings that repository already solved —
# all in npm's own bundled dependencies, none in application code. Deleting npm
# afterwards does not work either; a later layer writes whiteouts rather than
# reclaiming bytes. Never adding it is the only way to remove it.

FROM node:22-alpine AS node-source

# ── runtime ──────────────────────────────────────────────────────────────────
FROM alpine:3.21 AS runtime

# Base image pinned rather than apk versions: Alpine prunes superseded package
# versions from its index, so an exact pin stops resolving on the next patch.
# hadolint ignore=DL3018
RUN apk add --no-cache libstdc++ ca-certificates tini

# The node binary is dynamically linked against libstdc++ and libgcc, both
# pulled in above.
COPY --from=node-source /usr/local/bin/node /usr/local/bin/node

# Alpine has no `node` user; create the same uid the official image uses.
RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

# Baked at build time so a running container reports exactly which build it is.
# That is what makes a deployment verifiable rather than merely successful — the
# health check compares this against the tag being deployed.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    NODE_ENV=production \
    PORT=3000

WORKDIR /app
COPY --chown=1000:1000 app/package.json ./
COPY --chown=1000:1000 app/src ./src

USER 1000:1000
EXPOSE 3000

# Short interval and start period: a deployment waits on this, so slow health
# reporting is slow deployment.
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/server.js"]
