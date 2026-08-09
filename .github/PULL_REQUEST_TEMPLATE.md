## What changed

<!-- One or two sentences. -->

## Why

<!-- The problem being solved. Link an issue if there is one. -->

## Checks

- [ ] `make check` passes (actionlint, shellcheck, shfmt, hadolint, unit tests)
- [ ] Targets bash 3.2 — no `${var,,}` or associative arrays
- [ ] New behaviour has a test
- [ ] No secrets, real hostnames, real IPs, or account IDs

## Deployment safety

<!-- Could this leave a host serving nothing, or serving the wrong build? -->

- [ ] Verify-before-switch ordering preserved
- [ ] Failure paths leave live traffic untouched, and `tests/e2e.sh` asserts it
