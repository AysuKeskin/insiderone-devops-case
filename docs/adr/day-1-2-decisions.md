# Day 1-2 Architecture Decisions

This file captures the main Day 1 and Day 2 decisions so the reasoning stays
visible during the rest of the case study. Each note follows a lightweight ADR
style: status, context, decision, and consequences.

## ADR 001 - Go for the HTTP Service

Status: Accepted

I chose Go because the service is intentionally small, HTTP-focused, and needs
to build into a simple static binary. Go's standard library is enough for the
core endpoints, graceful shutdown, and tests, so there is no need for a web
framework at this stage. The main tradeoff is that Go 1.25 must be available in
local or containerized tooling, but `make docker-test` keeps local setup light.

## ADR 002 - Distroless Runtime Image

Status: Accepted

The container uses a multi-stage build and runs the final binary on
`gcr.io/distroless/static-debian12:nonroot`. This keeps the runtime image small
and removes shell, package manager, and debugging tools that are not needed in
production. The tradeoff is lower in-container debuggability, so debugging is
expected to happen through logs, Kubernetes events, or temporary debug
containers.

## ADR 003 - Non-root Container and Restricted Runtime

Status: Accepted

The app runs as the distroless `nonroot` user and the local Docker run drops all
Linux capabilities. The Helm chart also sets `runAsNonRoot`, `readOnlyRootFilesystem`,
`allowPrivilegeEscalation: false`, dropped capabilities, and a runtime default
seccomp profile. This adds a small amount of YAML, but it is useful production
signal for a service that should not need privileged filesystem or process
access.

## ADR 004 - Binary-based Docker Healthcheck

Status: Accepted

Distroless images do not include curl, wget, or a shell, so a shell-based
Docker healthcheck would weaken the runtime image choice. Instead, the server
binary supports a `healthcheck` command that calls `/healthz` with a short
timeout and exits non-zero on failure. This keeps the image minimal while still
satisfying the Day 1 container healthcheck expectation.

## ADR 005 - Separate Liveness and Readiness

Status: Accepted

The service exposes `/healthz` for liveness and `/readyz` for readiness instead
of using the same endpoint for both probes. During shutdown, the process flips
readiness to false before draining in-flight requests, which allows Kubernetes
to stop sending new traffic before the pod exits. This is slightly more code
than a single health endpoint, but it makes rolling updates and shutdown behavior
safer and easier to explain.

## ADR 006 - Structured Logs and Request IDs

Status: Accepted

The app uses Go's `log/slog` JSON handler and a request ID middleware that
reads or generates `X-Request-ID`. Request logs include timestamp, level,
message, request_id, method, path, status, duration, and remote address so a
basic incident investigation has useful context. Probe and metrics paths are
logged at debug level to reduce noise once Kubernetes and Prometheus are polling
the service.

## ADR 007 - Helm Instead of Raw Kubernetes Manifests

Status: Accepted

I use a small Helm chart rather than applying raw Kubernetes YAML files. Helm
packages the Deployment, Service, Ingress, ConfigMap, Secret, and HPA in one
repeatable unit and gives me `values-dev.yaml` and `values-prod.yaml` for
environment differences. The tradeoff is template syntax, but it buys clean
upgrades, rollbacks, and a familiar production deployment workflow.

## ADR 008 - Dev and Prod Values Files

Status: Accepted

The chart keeps common defaults in `values.yaml` and separates environment
differences into `values-dev.yaml` and `values-prod.yaml`. Dev stays small with
one replica and debug logs, while prod uses higher resources, info logs, HPA
enabled, and a different ingress host. This makes the environment differences
visible without duplicating the entire chart.

## ADR 009 - Safe RollingUpdate Strategy

Status: Accepted

The Deployment uses an explicit rolling update strategy with `maxSurge: 1` and
`maxUnavailable: 0`. This favors predictable, zero-downtime rollouts over raw
speed, which is a better fit for a small minikube cluster on a laptop or EC2.
The rollout may take a few extra seconds, but it never intentionally drops below
desired capacity and works well with readiness probes plus graceful shutdown.

## ADR 010 - Local Minikube Image Loading for Day 2

Status: Accepted

For the Day 2 local minikube workflow, `make deploy-dev` and `make deploy-prod`
set `image.pullPolicy=Never` because the image is loaded directly with
`minikube image load`. This avoids needing GHCR before the CI/CD day and keeps
the Day 2 checkpoint reproducible offline after the local build. For the later
EC2/GHCR flow, the chart default remains `IfNotPresent` and CI can override the
image tag explicitly.

## ADR 011 - Empty Secret Template, No Real Secrets in Git

Status: Accepted

The Helm chart includes a Secret template so the Kubernetes contract contains
both ConfigMap and Secret resources, but `secret.stringData` is empty by
default. Real values must come from `--set`, CI secrets, or a future external
secret manager rather than being committed to Git. This keeps the chart complete
for the case requirements while preserving the no-plaintext-secrets rule.
