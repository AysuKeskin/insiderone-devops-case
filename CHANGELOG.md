# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-25

First end-to-end slice: a small Go HTTP service that builds into a signed
container, deploys to minikube on EC2 through CI/CD, and exposes a public URL.

### Added

- **HTTP service** (`cmd/server`, `internal/`): `/ping`, `/healthz`, `/readyz`,
  `/version` endpoints with structured `log/slog` JSON logging, request-ID
  middleware, and graceful SIGTERM shutdown with a readiness drain.
- **Container**: multi-stage Dockerfile on `gcr.io/distroless/static-debian12:nonroot`,
  non-root uid 65532, binary-mode `HEALTHCHECK`, OCI source labels, digest-pinned
  base images.
- **Helm chart** (`helm/insiderone-devops-case`): Deployment, Service, Ingress,
  ConfigMap, Secret, HPA, with `values-dev.yaml` / `values-prod.yaml` overrides.
  Explicit `RollingUpdate` (`maxSurge: 1, maxUnavailable: 0`) for zero-downtime
  rollouts; separate liveness/readiness/startup probes; restricted pod and
  container `securityContext`. Ingress supports a hostless catch-all rule for
  raw-IP access on EC2.
- **CI** (`.github/workflows/ci.yml`): lint, race-tested unit tests, gitleaks
  secret scan, Trivy image scan (fails on CRITICAL/HIGH), GHCR push, cosign
  keyless signing, and an SPDX SBOM via Syft.
- **CD** (`.github/workflows/deploy.yml`): on green CI on `main`, assumes an AWS
  role via GitHub OIDC and runs `helm upgrade` on the EC2 host through SSM
  Send-Command — no SSH, no long-lived credentials.
- **Infrastructure** (`infra/terraform`): EC2 (t3.medium) + Elastic IP +
  security group (80/443 only, no SSH) + minikube bootstrap, plus the GitHub
  OIDC provider and a least-privilege deploy role scoped to this repo.
- **Docs**: ADRs for Days 1-3 decisions, RUNBOOK, and a README front door.

### Security

- No long-lived cloud credentials: GitHub Actions authenticates to AWS via
  short-lived OIDC tokens; the EC2 security group has no SSH ingress.
- Supply chain: images are signed (cosign) and ship an SBOM (Syft); the base
  image is digest-pinned and Trivy gates every build.

[0.1.0]: https://github.com/AysuKeskin/insiderone-devops-case/releases/tag/v0.1.0
