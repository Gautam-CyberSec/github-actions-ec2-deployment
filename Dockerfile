# syntax=docker/dockerfile:1
#
# Deliberately small. The multi-stage build, npm removal and read-only runtime
# rationale live in docker-node-postgres-stack; this image exists to be deployed,
# not to re-demonstrate container hardening.

FROM node:22-alpine AS runtime

# Base image pinned rather than apk versions: Alpine prunes superseded package
# versions from its index, so an exact pin stops resolving on the next patch.
# Established in docker-node-postgres-stack; see that repository's LESSONS.md.
# hadolint ignore=DL3018
RUN apk add --no-cache tini

# APP_VERSION is baked at build time so a running container can report exactly
# which build it is — that is what makes a deployment verifiable rather than
# merely successful.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    NODE_ENV=production \
    PORT=3000

WORKDIR /app
COPY --chown=1000:1000 app/package.json ./
COPY --chown=1000:1000 app/src ./src

USER 1000:1000
EXPOSE 3000

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/server.js"]
