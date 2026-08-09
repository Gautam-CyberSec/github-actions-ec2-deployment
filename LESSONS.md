# Engineering Decisions &amp; Lessons Learned

Mistakes made while building this pipeline and what each one changed. Every entry
below actually happened during development; none are illustrative.

Each lesson records **Problem**, **Cause**, **Discovery**, **Fix** and the
**Engineering Principle** that now prevents it.

Neither Docker nor AWS was available on the development machine, so everything
container- or deployment-shaped was verified through CI. That is why most of
these were found there.

---

## 1. An image that built, pushed, and could not be scanned

**Problem**
The build job pushed three images to GHCR successfully and then failed:

```
FATAL  run error: image scan error: unable to initialize a scan service:
failed to parse the image name: could not parse reference:
ghcr.io/Gautam-CyberSec/github-actions-ec2-deployment:sha-5840410-1
```

**Cause**
GHCR rejects uppercase image names, and `github.repository` preserves the
account's casing. The build and push steps lowercased it inline; the Trivy step
used `${{ github.repository }}` directly. Two representations of the same image
existed in one job, and only one of them was valid.

**Discovery**
The CI log. The failure was misleading at first glance — the job is named
`build · push · scan` and the push had clearly worked, so the natural reading was
a scanner problem rather than a name problem. The parse error in the message was
what separated them.

**Fix**
Compute the lowercase repository once into `GITHUB_ENV` and use that everywhere
in the job, so no step can construct its own variant.

**Engineering Principle**
*Derive a value once and pass it around; do not recompute it per use site.* Two
places doing the same transformation is one place that will eventually be
forgotten — and the failure surfaces far from the omission.

---

## 2. Citing a solution is not applying one

**Problem**
Once the scan actually ran, it failed with HIGH/CRITICAL findings in `sigstore`,
`tar` and other npm-bundled packages — the exact findings
`docker-node-postgres-stack` had already solved.

**Cause**
The Dockerfile here was deliberately kept minimal, with a comment pointing at the
sibling repository: *"the multi-stage build, npm removal and read-only runtime
rationale live in docker-node-postgres-stack; this image exists to be deployed,
not to re-demonstrate container hardening."*

That reasoning is fine for documentation and wrong for a build. Not repeating an
*explanation* is good; not repeating the *implementation* means shipping the
vulnerability the sibling repository exists to have fixed.

**Discovery**
The Trivy gate, on the run immediately after the image-name fix. The first run
never got far enough to find it, so one bug was hiding another.

**Fix**
Apply the established pattern: build the runtime from bare `alpine:3.21` and copy
in only the `node` binary. The comment now says the pattern is *applied* here and
explains why, rather than deferring to another repository.

**Engineering Principle**
*Reuse means using the implementation, not linking to it.* A cross-reference
tells a reader where the thinking lives; it does not put the fix in the artefact.
Anything a security gate checks has to be present, not cited.

---

## 3. A link checker that fails when there is nothing to check

**Problem**
The docs job failed with:

```
| 🚫 Errors      | 0     |
No links were found. This usually indicates a configuration error.
```

Zero errors, and a non-zero exit.

**Cause**
The documentation was committed as placeholder stubs — single-heading files — so
that CI could run against the real code before the prose was written from its
output. lychee treats an empty link set as a misconfiguration rather than a pass,
which is reasonable behaviour and surprising in this order of work.

**Discovery**
The docs job, on the first push. It kept failing across three runs while the more
interesting build and deployment failures were being fixed, which made it easy to
read as noise rather than as a signal about sequencing.

**Fix**
Write the documentation from the verified CI output, which is what the stubs were
placeholders for. The job passes once the files contain real content and real
links.

**Engineering Principle**
*A tool reporting zero problems and still failing is telling you about your
inputs, not your content.* Committing deliberate placeholders is a reasonable way
to get code under CI early — but a placeholder that trips an unrelated gate makes
every subsequent run noisier, and the noise costs more than the head start.

---

## What this repository does differently as a result

- The deployment script is exercised end to end on every push, against a real SSH
  host with real Docker and real nginx, rather than only when deploying.
- Zero downtime is asserted by polling continuously across a live switch and
  requiring **0** failed requests, not claimed in prose.
- A deploy of a non-existent tag is asserted to fail *and* to leave the upstream
  untouched, so the rollback path is tested rather than assumed.
- Health means healthy **and** running the expected build; a container reporting
  OK on the previous image counts as a failed deployment.
- Image names are normalised once per job, and container hardening is applied
  from the established pattern rather than referenced.
