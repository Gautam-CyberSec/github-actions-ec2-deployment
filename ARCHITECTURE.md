# Architecture

Why the pipeline is shaped this way, and what was rejected.

## The problem with deployment code

Deployment scripts are usually the least tested code in a repository. They run
last, in production, and the only way to find out whether they work is to use
them. A bug in one is discovered at the worst possible moment.

So the target here is a **generic SSH host**, not EC2 specifically. `deploy.sh`
takes `--host`, `--user`, `--key` and `--known-hosts`, and does not know or care
what is on the other end. Production points it at an instance. CI points it at a
host it controls — the GitHub runner, with real `sshd`, real Docker and real
nginx — and runs the whole path on every push.

The same script, exercised the same way, without an AWS account.

## Blue/green on one host

Two containers, fixed ports, one nginx upstream:

| Colour | Port | Container |
|---|---|---|
| blue | 3001 | `deploy-payload-blue` |
| green | 3002 | `deploy-payload-green` |

Ports are fixed rather than allocated, so a half-finished deploy leaves the host
in a state a human can reason about at 3am.

The active colour is **read from the host**, not tracked in CI:

```
grep -oE 'Active colour: (blue|green)' /etc/nginx/conf.d/upstream.conf
```

The upstream file is therefore both the routing configuration and the record of
what is live. There is no second source of truth to drift, and a deploy that ran
from someone's laptop is still accounted for.

## The order of operations

1. Read the active colour; the deploy targets the other one.
2. Pull the image by immutable tag.
3. Start the inactive colour on its own port.
4. Health-check it **and confirm it reports the tag being deployed**.
5. Render a new upstream, `nginx -t`, then reload.
6. Verify through the proxy.
7. Stop — not remove — the old container.

Everything before step 5 is reversible by deleting one container: live traffic
has not moved. After step 5, failure restores the previous upstream. There is no
window where both the old and new configuration are half-applied, because the
upstream is written to a temp file and moved into place atomically.

## Health is a version check

A container that answers `{"status":"ok"}` while still running the previous image
has not deployed. `health_is_ok` therefore compares the reported version against
the tag being deployed:

```json
{"status":"ok","version":"sha-390d146-2","color":"green","uptime_s":0}
```

This is also why `:latest` is rejected in code. A moving tag makes the comparison
meaningless — the deploy cannot say what it deployed, and a rollback cannot name
what it is returning to.

## Reload, not restart

`nginx -s reload` starts new worker processes for new connections and lets the
old workers finish what they are serving. `restart` cuts them.

Combined with `proxy_next_upstream` and one retry, a request that arrives during
the switch is retried against the new colour rather than failing. The end-to-end
test polls continuously across a live deploy and asserts **0** failed requests.

## Stopped, not removed

The retired container is stopped and kept. Rolling back is then:

```bash
docker start deploy-payload-blue   # and point the upstream back
```

rather than a pull. That difference matters exactly when the registry is the
thing that broke — the situation where you most want to go back.

## Least privilege on the host

`bootstrap.sh` grants the deploy user sudo for two commands:

```
deploy ALL=(root) NOPASSWD: /usr/sbin/nginx, /bin/mv
```

`mv` to place the rendered upstream, `nginx` to test and reload. Nothing else.
The file is validated with `visudo -c` before it is left in place, and removed if
validation fails — a malformed sudoers file can lock out sudo entirely.

The deploy user is in the `docker` group, which is effectively root on that host.
That is a real limitation and is stated in [SECURITY.md](SECURITY.md), not hidden.

## Secrets

The workflow writes the SSH key under `umask 077`, never echoes it, and shreds it
in an `always()` step. GHCR authentication uses the automatic `GITHUB_TOKEN`
rather than a stored personal token: scoped to this repository, rotated per run,
and impossible to leak from a settings page because it is never stored.

Host key verification is on. `StrictHostKeyChecking=no` would make the script work
everywhere and authenticate nothing — the difference between deploying to your
server and deploying to whoever answers.

## What is deliberately absent

- **Terraform for the instance.** The VPC and IAM baseline is
  [terraform-aws-vpc-baseline](https://github.com/Gautam-CyberSec/terraform-aws-vpc-baseline);
  duplicating it here would make this repository about infrastructure rather than
  deployment.
- **A container registry of its own.** GHCR is already available and authenticated.
- **Multiple hosts or a load balancer.** Blue/green across a fleet is an ALB
  target-group swap, which is a different design. This is the single-host case,
  stated as such.
- **Automatic deploy on every push.** Available in three lines; deliberately not
  the default, because a reader copying this should opt in.
- **Database migrations.** Blue/green with a shared database needs
  backward-compatible schema changes, which is a design constraint on the
  application rather than on the pipeline.
