# Roadmap

Ordered by what would most improve the pipeline, not by ease.

## Next

- [ ] **Verify against a real EC2 instance.** The single biggest gap. Everything
      is tested against an SSH host that behaves like one, but EC2-specific
      behaviour — instance profiles, IMDSv2, security groups — is unverified.
- [ ] **A `rollback.sh` command.** Rollback is currently automatic on a failed
      deploy and manual afterwards. The previous container is deliberately kept
      stopped, so an explicit one-command rollback is a small addition.
- [ ] **Deployment metadata on the host.** A small JSON file recording tag, time
      and colour, so history is inspectable without reading nginx configuration.

## Later

- [ ] **Multi-host blue/green** via an ALB target-group swap. A different design
      from the single-host case, not an extension of it.
- [ ] **Migration gating.** Blue/green with a shared database requires
      backward-compatible schema changes; the pipeline could refuse to deploy
      when a migration is not marked safe.
- [ ] **Image signing and provenance** — cosign plus SLSA attestation, so the
      host can verify what it pulls rather than trusting the registry.
- [ ] **Canary weighting.** nginx can split traffic by weight; a deploy could
      hold at 10% and watch error rates before completing the switch.
- [ ] **Deployment metrics** — duration, failure rate, rollback frequency —
      published from the workflow.

## Considered and rejected

- **Automatic deploy on every push to main.** Three lines to enable, deliberately
  off. A reference repository should not hand a reader continuous deployment
  without them choosing it.
- **A deployment agent on the host.** Removes the SSH dependency and adds a
  service to run, secure and update. Not worth it for a single host.
- **Terraform for the instance.** Belongs in
  [terraform-aws-vpc-baseline](https://github.com/Gautam-CyberSec/terraform-aws-vpc-baseline).
