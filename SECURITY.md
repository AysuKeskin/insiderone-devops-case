# Security

This is a case-study repository, but it is built with production security habits.
This page covers how to report an issue and what protections are already in place.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository, or contact the
maintainer (`@AysuKeskin`). Please do not open a public issue for an unpatched
vulnerability. There is no SLA — this is a demo project — but reports are
welcome and will be acknowledged.

## Supported versions

| Version | Supported |
|---|---|
| `0.1.x` | ✅ |

## What protects the supply chain

Every image that reaches the registry has passed, in CI (`.github/workflows/ci-cd.yml`):

- **Trivy** image scan — the pipeline fails on any `CRITICAL` or `HIGH` OS/library
  vulnerability (`--ignore-unfixed`), and scans the image **before** it is pushed.
- **gitleaks** — secret scan on every push and PR; the repo holds no real
  credentials (only `.env.example` placeholders).
- **cosign** — images are signed keyless via GitHub OIDC. Verify:
  ```sh
  cosign verify ghcr.io/aysukeskin/insiderone-devops-case:<tag> \
    --certificate-identity-regexp 'https://github.com/AysuKeskin/insiderone-devops-case/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
- **Syft SBOM** — an SPDX SBOM is produced for every image, attached to each
  GitHub Release, and bound to the image itself as a cosign attestation
  (`cosign attest --type spdxjson`). Verify the attestation:
  ```sh
  cosign verify-attestation ghcr.io/aysukeskin/insiderone-devops-case:<tag> \
    --type spdxjson \
    --certificate-identity-regexp 'https://github.com/AysuKeskin/insiderone-devops-case/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
- **Digest-pinned base images** — the Dockerfile pins both the build and runtime
  images by `sha256` digest, so builds are reproducible and can't drift.

## Runtime hardening

- **Distroless, non-root** — runs on `gcr.io/distroless/static-debian12:nonroot`
  as uid `65532`; no shell or package manager in the image.
- **Locked-down container** — `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
  all Linux capabilities dropped, `seccompProfile: RuntimeDefault`.
- **No long-lived cloud credentials** — GitHub Actions authenticates to AWS via
  short-lived OIDC tokens assuming a role scoped to this repo's `main` branch and
  `v*` tags. No access keys are stored anywhere.
- **No SSH** — the EC2 security group has no port 22 ingress; operator access is
  via AWS SSM Session Manager (audited through CloudTrail).
- **Minimal network surface** — the security group allows only `80`/`443` inbound;
  IMDSv2 is required on the instance.
- **TLS in transit** — the public endpoint is served over HTTPS: the ingress
  terminates a Let's Encrypt certificate issued by cert-manager (DNS-01), and
  Cloudflare fronts it in Full (strict) mode.
- **No secrets in git** — Kubernetes Secrets are injected at deploy time; the chart
  ships an empty Secret contract, never real values.

## Known, accepted exposure

- The app's `/metrics` endpoint is reachable on the public URL. It exposes request
  counters and Go runtime stats only — no secrets or request bodies — so it is left
  open for this demo. In a hardened deployment it would sit behind the ingress's
  internal-only path or network policy.
