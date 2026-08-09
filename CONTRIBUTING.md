# Contributing

Issues and pull requests are welcome.

## Before opening a pull request

```bash
make check      # actionlint, shellcheck, shfmt, hadolint, unit tests
make dry-run    # a deployment plan that contacts nothing
```

CI runs both, plus the image build, a Trivy scan, and the full deployment against
a real SSH host.

## Conventions

- **Portable bash.** Target bash 3.2, not 4+. No `${var,,}`, no associative
  arrays. CI enforces this on a macOS runner.
- **Deployment logic stays pure.** Functions in `deploy/lib.sh` take arguments
  and return strings — no SSH, no Docker, no network. That is what keeps the unit
  suite runnable without a host, and new logic follows the same shape.
- **Anything that can take down a live service needs a guard and a test.** The
  health-then-switch ordering is the model: verify first, switch second, roll
  back on failure, and assert all three in `tests/e2e.sh`.
- **Claims are asserted, not described.** If the README says zero downtime, a
  test polls across a deploy and counts failures.
- **Workflows are source.** They are linted with `actionlint` and reviewed like
  code.
- **No secrets, real hostnames, real IPs, or account IDs** in any committed file,
  including examples.

## Adding a deployment step

1. Put any decision logic in `deploy/lib.sh` as a pure function.
2. Add unit tests, including the failure path.
3. Wire it into `deploy/deploy.sh`, preserving verify-before-switch ordering.
4. Add an assertion to `tests/e2e.sh`.
5. Update the README table if it changes observable behaviour.

## Reporting a security issue

Do not open a public issue — see [SECURITY.md](SECURITY.md).
