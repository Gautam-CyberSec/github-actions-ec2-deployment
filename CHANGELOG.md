# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
See [ROADMAP.md](ROADMAP.md) — verification against a real EC2 instance, an
explicit `rollback.sh`, and deployment metadata on the host.

## [1.0.0] — 2026-08-09

Initial release.

### Added
- `deploy/deploy.sh` — blue/green deployment over SSH: reads the active colour
  from the host, deploys to the other one, health-checks it against the expected
  build, switches the nginx upstream, verifies through the proxy, and stops the
  old container only after that.
- `deploy/lib.sh` — colour selection, port mapping, image references, nginx
  rendering and health verification as pure functions.
- `deploy/remote/bootstrap.sh` — one-time host preparation with sudo scoped to
  `nginx` and `mv`, validated by `visudo -c`.
- 33 unit tests requiring no SSH, Docker or AWS.
- `tests/e2e.sh` — 13 checks running the real deploy script against a live SSH
  host with real Docker and nginx.
- CI: actionlint, shellcheck, shfmt, hadolint, nginx config validation, unit
  tests on Linux and macOS bash 3.2, image build and push to GHCR, Trivy, the
  full end-to-end deployment, and a markdown link check.
- `.github/workflows/deploy.yml` — production deployment, manual or on release,
  gated behind a `production` environment.

### Security
- Host key verification enabled; `known_hosts` supplied as a secret.
- `:latest` refused in code — immutable tags only.
- Containers run as uid 1000 with a read-only root filesystem,
  `no-new-privileges`, and memory and PID limits, published on loopback only.
- Runtime image built from bare Alpine with the node binary copied in, so no
  package manager ships. 0 HIGH/CRITICAL findings.
- Credentials written under `umask 077` and shredded in an `always()` step.
- GHCR authentication via the per-run `GITHUB_TOKEN` rather than a stored token.

### Verified
- Deploys alternate colour; the health gate compares the reported version against
  the deployed tag; continuous polling across a live switch records 0 failed
  requests; a deploy of a non-existent tag fails and leaves the upstream
  untouched.
- **Not** verified against a real EC2 instance — see
  [SECURITY.md](SECURITY.md#what-is-not-verified).

[Unreleased]: https://github.com/Gautam-CyberSec/github-actions-ec2-deployment/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Gautam-CyberSec/github-actions-ec2-deployment/releases/tag/v1.0.0
