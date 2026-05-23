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
| `make clean` | remove `bin/` | — |

If Go isn't installed locally, use `make docker-test` / `make docker-build` / `make docker-run` — Docker is enough.

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `PORT` | `8080` | container listen port (must be ≥ 1024, non-root) |
| `HOST_PORT` | `8080` | host port mapped by docker compose only |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

See `.env.example`. In production (Kubernetes), config comes from the ConfigMap in the Helm chart, not `.env`.

## Production-aware extras

- **Multi-stage Dockerfile** → distroless `static-debian12:nonroot` base pinned by digest, non-root uid `65532`, ~7 MB image.
- **Docker `HEALTHCHECK`** → uses `/server healthcheck`, so the distroless runtime image does not need curl, wget, or a shell.
- **OCI image labels** (`org.opencontainers.image.source` etc.) so GHCR links the image back to the repo.
- **`/healthz` vs `/readyz`** wired to liveness vs readiness probes separately.
- **Request-ID middleware** generates `X-Request-ID` per request and emits it on every log line.
- **Structured JSON logs** via `log/slog` — fields: `timestamp, level, msg, request_id, method, path, status, duration_ms`. `/healthz`, `/readyz`, `/metrics` are demoted to `DEBUG` to avoid probe noise.
- **Graceful shutdown** — on SIGTERM, flips `/readyz` to 503 and drains in-flight requests (15s deadline) so Kubernetes rolling updates don't drop traffic.

## Layout

```
cmd/server/        entrypoint, lifecycle wiring
internal/handlers/ /ping /healthz /readyz /version
internal/middleware/ request-id, access log
internal/version/  ldflags-populated build info
helm/              (Day 2) Helm chart with dev/prod values
infra/terraform/   (Day 3) EC2, EIP, SG, IAM OIDC role
.github/workflows/ (Day 3) CI + deploy
```
