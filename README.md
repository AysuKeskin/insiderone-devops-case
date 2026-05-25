# insiderone-devops-case

A tiny Go HTTP service for the Insider One DevOps 2026 case study.
End-to-end slice: app → container → Helm/minikube → CI/CD → observability → public URL.

**Track:** A — minikube on AWS EC2 (Elastic IP exposed).

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/ping` | returns `pong` |
| GET | `/healthz` | liveness probe (always 200 if process is up) |
| GET | `/readyz` | readiness probe (503 during shutdown drain) |
| GET | `/version` | build info: version, commit, built_at |
| GET | `/metrics` | Prometheus exposition (added Day 4) |

## Quick start

```sh
make help          # list all targets
make docker-build  # build the container image
make docker-run    # run it on :8080
curl localhost:8080/ping        # → pong
```

## All Makefile targets

| Target | What it does | Needs |
|---|---|---|
| `make help` | list targets | — |
| `make run` | run server with `go run` | Go 1.25+ |
| `make build` | build local binary into `bin/server` | Go 1.25+ |
| `make test` | unit tests with race detector + coverage | Go 1.25+ |
| `make docker-test` | run tests inside a `golang:1.25` container | Docker only |
| `make lint` | `go vet ./...` | Go 1.25+ |
| `make docker-build` | multi-stage build, tags image with git SHA + `latest` | Docker |
| `make docker-run` | run container on `:8080`, read-only, all caps dropped | Docker |
| `make compose-up` | `docker compose up --build` (local dev) | Docker |
| `make compose-down` | `docker compose down` | Docker |
| `make scan` | Trivy scan, fails on `CRITICAL`/`HIGH` | Trivy |
| `make helm-lint` | lint the Helm chart against dev values | Helm |
| `make helm-template` | render templates locally for inspection | Helm |
| `make minikube-load` | load the locally-built image into minikube | minikube |
| `make deploy-dev` | `helm upgrade --install` with `values-dev.yaml` | Helm + kubectl |
| `make deploy-prod` | `helm upgrade --install` with `values-prod.yaml` | Helm + kubectl |
| `make rollout-status` | wait for the current Deployment rollout (2 min cap) | kubectl |
| `make rollout-dev` | `deploy-dev` then wait for pods to be Ready | Helm + kubectl |
| `make rollout-prod` | `deploy-prod` then wait for pods to be Ready | Helm + kubectl |
| `make rollback` | `helm rollback` to previous revision | Helm |
| `make helm-history` | show release revision history | Helm |
| `make helm-uninstall` | remove the release | Helm |
| `make clean` | remove `bin/` | — |

If Go isn't installed locally, use `make docker-test` / `make docker-build` / `make docker-run` — Docker is enough.

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `PORT` | `8080` | container listen port (must be ≥ 1024, non-root) |
| `HOST_PORT` | `8080` | host port mapped by docker compose only |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

See `.env.example`. In production (Kubernetes), config comes from the ConfigMap in the Helm chart, not `.env`.

## Deploy to Kubernetes (local minikube)

```sh
minikube start --driver=docker --cpus=2 --memory=4096
minikube addons enable ingress
minikube addons enable metrics-server   # for HPA in prod values
make docker-build
make minikube-load                       # push the local image into minikube
make rollout-dev                         # deploy dev (1 replica, debug) then wait
make rollout-prod                        # deploy prod (3 replicas, HPA) then wait
make helm-history
make rollback && make rollout-status     # revert and wait for old image to come back
```

`make deploy-dev` and `make deploy-prod` set `image.pullPolicy=Never` only for
this local minikube flow, because the image is loaded directly into minikube.
For the later EC2/GHCR deployment, the chart default `IfNotPresent` is used
instead, or CI can override it explicitly.

The `values-dev.yaml` and `values-prod.yaml` deliberately differ on replica count, log level, resources, ingress host, and HPA settings — see those files for the deltas. Resource requests/limits are conservative starting estimates for a static Go binary that idles near zero CPU and ~10 Mi memory; dev sits at the floor (50m / 64Mi requests) and prod doubles both for traffic headroom. They will be tuned against real `kubectl top pod` numbers once load is generated in Day 4.

### Rollout strategy

Deployments use an explicit `RollingUpdate` with `maxSurge: 1, maxUnavailable: 0`. The intent is **safe and verifiable rollout/rollback over raw speed** — we'd rather have a predictable pod footprint in small clusters (minikube on a laptop, single-node EC2) than save a handful of seconds by surging to 2× replicas. Even when HPA scales us to 10 replicas, only one extra pod ever exists during a rollout. At `maxUnavailable: 0` the chart never drops below desired capacity, so client requests keep flowing while the new image takes over. This pairs with the app's graceful SIGTERM drain to deliver true zero-downtime rollouts.

### Rollout & rollback exercise

The `/version` endpoint makes rollouts observable end-to-end. With `helm upgrade --set image.tag=<new>` the response flips to the new tag; `helm rollback` immediately flips it back. Evidence captured to `docs/evidence/version-before-bump.txt`, `version-after-bump.txt`, `version-after-rollback.txt`, plus `helm-history-final.txt` showing the full revision chain (install → upgrade → upgrade → upgrade → rollback → upgrade → rollback).

## Chaos test

Killed one pod from a 3-replica deployment to observe Kubernetes self-healing:

```sh
kubectl delete pod <one-of-three-pods>
```

A replacement pod was scheduled within ~2 seconds and reached `Ready` shortly after. Replica count stayed at 3 throughout because HPA's `minReplicas: 3` floor enforces it independent of CPU metrics. What I learned: the Deployment controller doesn't wait for the dead pod to be `Terminated` before creating the replacement — it reacts to the desired-vs-actual delta immediately, so a graceful shutdown drain and a new pod's startup overlap cleanly. Evidence in `docs/evidence/chaos-*.txt`.

## Production-aware extras

- **Multi-stage Dockerfile** → distroless `static-debian12:nonroot` base pinned by digest, non-root uid `65532`, ~7 MB image.
- **Docker `HEALTHCHECK`** → uses `/server healthcheck`, so the distroless runtime image does not need curl, wget, or a shell.
- **OCI image labels** (`org.opencontainers.image.source` etc.) so GHCR links the image back to the repo.
- **`/healthz` vs `/readyz`** wired to liveness vs readiness probes separately.
- **Request-ID middleware** generates `X-Request-ID` per request and emits it on every log line.
- **Structured JSON logs** via `log/slog` — fields: `timestamp, level, msg, request_id, method, path, status, duration_ms`. `/healthz`, `/readyz`, `/metrics` are demoted to `DEBUG` to avoid probe noise.
- **Graceful shutdown** — on SIGTERM, flips `/readyz` to 503 and drains in-flight requests (15s deadline) so Kubernetes rolling updates don't drop traffic.

## Cloud infrastructure

Track A target: a single EC2 host in `eu-central-1` running minikube, reachable on an Elastic IP. Provisioned with Terraform under `infra/terraform/`.

```sh
cd infra/terraform
terraform init
terraform apply             # ~3 min; spins up EC2 + EIP + SG + GitHub OIDC role
terraform output            # AWS_REGION, AWS_ROLE_ARN, EC2_INSTANCE_ID for GH secrets
terraform destroy           # full teardown when the demo window is closed
```

The stack is intentionally narrow: no SSH (port 22 is closed at the SG), no long-lived AWS keys (GitHub Actions assumes the `gha_deploy` role via OIDC), and no GHCR secret on the host (the image is published as a public package, so minikube pulls anonymously). See `docs/adr/day-3-decisions.md` for the deploy-via-SSM and `t3.small` tradeoffs.

## Layout

```
cmd/server/        entrypoint, lifecycle wiring
internal/handlers/ /ping /healthz /readyz /version
internal/middleware/ request-id, access log
internal/version/  ldflags-populated build info
helm/insiderone-devops-case/
                   Helm chart: Deployment, Service, Ingress, ConfigMap,
                   Secret, HPA, values-dev.yaml, values-prod.yaml
docs/evidence/     command output evidence: helm history, rollout, rollback, chaos
infra/terraform/   EC2, EIP, SG, IAM OIDC role (Track A)
.github/workflows/ (Day 3) CI + deploy
```
