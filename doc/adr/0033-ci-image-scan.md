# ADR 0033: Scan the images for known vulnerabilities in CI

**Status:** Accepted · **Date:** 2026-10-28 · **Issues:** #77

## Decision

Every push and pull request runs the CI job "Image Vulnerability Scan". It builds our 3 images (from the build job's cache) and scans them with Trivy 0.76.1, with PostgreSQL and Redis at the digests `k8s/` pins: 5 images, vulnerabilities only (`--scanners vuln`), `HIGH` and `CRITICAL`. The job **fails on a `CRITICAL` vulnerability that has a fixed version**, unless `.trivyignore.yaml` accepts it with a reason. Everything else is reported in the job summary, readable from the PR: a count per image, the full list, and each blocking one as an error. Trivy is the release binary, pinned and checked against its SHA-256, not its GitHub Action.

## Why

- **The threshold fails only on what we can act on:** a `CRITICAL` with a fix means a newer base image or dependency removes it. A vulnerability with no fix, or a `HIGH` one, would keep the CI red with nothing to change: first scan, 49 `HIGH` in Poll, 64 in Result, 26 in PostgreSQL, mostly in base image packages.
- **First scan, 2026-10-28:** no fixable `CRITICAL` in Poll, the worker, Result and Redis (Result has 1 `CRITICAL` with no fix). PostgreSQL 18.6 has 3, and its latest official image is the one we pin, so we accept them in `.trivyignore.yaml`, each with its reason:
  - 2 in `gosu`, built with Go 1.24.6. **Fact:** the image's entrypoint only runs `gosu` when the container starts as root. ([docker-library/postgres: docker-entrypoint.sh](https://github.com/docker-library/postgres/blob/master/docker-entrypoint.sh)) Our pod runs as UID 70, so the binary is never executed. The exception is limited to that file's path.
  - 1 in `brotli-libs`, fixed in Alpine but not yet in the official image. It expires on 2026-11-30: after that date, the CI fails on it again, unless Dependabot has brought the rebuilt image.
- **The gate works:** checked locally with `python:3.8-slim`, an old image: 7 fixable `CRITICAL`, listed as errors, exit 1. With a past `expired_at`, the `brotli-libs` one blocks again.
- **The binary, not the action:** **Fact:** on 2026-03-19, stolen credentials were used to force-push 76 of the 77 tags of `aquasecurity/trivy-action` and every tag of `aquasecurity/setup-trivy` to credential-stealing code, and to publish a malicious Trivy v0.69.4. ([GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)) A tag can move; a checksum cannot. The v0.76.1 release is also marked immutable on GitHub.
- **Fact:** an entry of `.trivyignore.yaml` can be limited to paths and given an `expired_at` date, after which it no longer applies; the YAML format is experimental and needs `--ignorefile`. ([Trivy docs: filtering](https://trivy.dev/docs/latest/configuration/filtering/)) The Trivy version is pinned, so the format cannot change under us.

## Trade-offs

- **A PR can turn red with no code change:** the vulnerability database changes several times a day. That is the point: a new fixable `CRITICAL` in an image we run is news. Update the image, or accept it in `.trivyignore.yaml` with a reason.
- **Scanned when CI runs, not over time:** an image already in the registry is not rescanned when a new CVE comes out ([ADR 0023](0023-security-posture.md)).
- **Slower CI:** the job builds the 3 images again (from the cache) and downloads Trivy's databases, including the Java one (about 1.5 GB) for the worker's jar; hence `--timeout 15m`. It runs in parallel with the other jobs.
- Trivy's version is a manual edit, like kubeconform's; Dependabot does not see it.

## Alternatives rejected

- **`aquasecurity/trivy-action`:** the hijacked tags above. Pinning it by commit would be safe, but it downloads the same binary through one more layer.
- **Grype:** a comparable scanner, with no gap that would justify leaving Trivy, the one proposed in the issue.
- **Docker Scout:** tied to a Docker account. **Microsoft Defender for Containers:** rescans the registry over time, but it is a paid plan on a student credit.
- **Fail on `HIGH` too:** a red CI on base image issues we cannot fix.
- **Gate only our 3 images:** a fixable `CRITICAL` in PostgreSQL or Redis would never block, and a new digest from Dependabot would go unchecked.
- **SARIF upload to the Security tab:** one more action and the `security-events: write` permission; the job summary is enough to read the result from the PR.
