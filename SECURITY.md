# Security policy

## Reporting a vulnerability

Email [gautamdem@gmail.com](mailto:gautamdem@gmail.com). Please do not open a
public issue. Acknowledgement within 72 hours.

## Controls, and where they are enforced

| Control | Where | Asserted by |
|---|---|---|
| Host key verification (`StrictHostKeyChecking=yes`) | `deploy/deploy.sh` | `known_hosts` supplied in the e2e test |
| Deploy user sudo limited to `nginx` and `mv` | `deploy/remote/bootstrap.sh` | `visudo -c` before the grant is kept |
| No `:latest` — immutable tags only | `deploy/lib.sh` | Unit test |
| Container runs as uid 1000, read-only rootfs | `deploy/lib.sh` | Unit tests on the generated command |
| `no-new-privileges`, memory and PID limits | `deploy/lib.sh` | Unit test |
| App published on loopback only, never `0.0.0.0` | `deploy/lib.sh` | Unit test |
| Image runs as non-root | `Dockerfile` | CI asserts `Config.User` is `1000:1000` |
| No fixable HIGH/CRITICAL CVEs | CI | Trivy, `--ignore-unfixed` |
| GHCR auth via `GITHUB_TOKEN` | `.github/workflows/` | Scoped per run, never stored |
| Credentials shredded after use | `.github/workflows/deploy.yml` | `always()` cleanup step |
| Deployment requires approval | `.github/workflows/deploy.yml` | `environment: production` |

## Secrets

Four repository secrets, scoped to a `production` environment: `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`.

Nothing is committed. `.gitignore` excludes `*.pem`, `*_key`, `*_key.pub` and
`known_hosts` so a locally generated test key cannot be added by accident. The
key used in CI is generated per run, authorises only the runner's own account,
and is discarded with the runner.

No AWS credentials exist anywhere in this repository. Deployment authenticates
with SSH, not with the AWS API.

## What is not verified

Stated plainly, because a pipeline that claims more than it has tested is worse
than one that claims less.

- **This has never run against a real EC2 instance.** No AWS account was used.
  The deployment path is exercised against a real SSH host with real Docker and
  real nginx in CI, which covers the script, the ordering, the health gate, the
  switch and the rollback — but not instance profiles, security groups, IMDS,
  EBS behaviour or anything else EC2-specific.
- **The `deploy.yml` workflow itself is unexercised.** It has been linted with
  `actionlint` and its secret handling reviewed, but it has never run: doing so
  requires a host that does not exist. The script it calls *is* tested.
- **Zero downtime is verified for this workload**, which is a stateless service
  with a sub-second start. A slower or stateful application would need its own
  measurement.
- **The deploy user is in the `docker` group**, which is equivalent to root on
  that host. This is inherent to deploying containers over SSH without a daemon
  socket proxy; it is a real limitation, not an oversight.

## Recommended hardening of the host itself

This repository configures a deployment path, not a server baseline. Harden the
instance with
[Linux-Server-Hardening](https://github.com/Gautam-CyberSec/Linux-Server-Hardening):
key-only SSH, root login disabled, default-deny firewall with only 22, 80 and 443
open, and unattended security updates.
