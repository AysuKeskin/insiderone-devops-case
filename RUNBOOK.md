# Runbook

Short incident-response guide for the `insiderone-devops-case` service running on
minikube on EC2 (app), with monitoring on local minikube (Prometheus + Grafana).

## Topology

- **Host**: one EC2 instance (`t3.medium`, Amazon Linux 2023) in `eu-north-1`,
  fronted by an Elastic IP. Provisioned by `infra/terraform`.
- **Cluster**: single-node minikube (docker driver), owned by `ec2-user`.
  One release: `insiderone-devops-case` (default namespace).
- **Access**: no SSH. Get a shell with
  `aws ssm start-session --target <instance-id> --region eu-north-1`.
- **Public URL**: `http://<elastic-ip>/` (ingress catch-all → service → pods).

## Deploy

Normal path is automatic: a push to `main` runs the `CI/CD` pipeline, and on
green CI the final `deploy` job rolls the new image out via SSM (`helm --atomic`
auto-rolls-back if it can't reach Ready). To deploy a specific tag by hand (or
re-deploy after a fix), run it on the box inside an SSM session as ec2-user:

```sh
cd /opt/app && git pull --ff-only
helm upgrade --install insiderone-devops-case ./helm/insiderone-devops-case \
  -f helm/insiderone-devops-case/values-prod.yaml \
  --set-string image.tag=sha-<short> --atomic --timeout 3m
kubectl rollout status deployment/insiderone-devops-case --timeout=3m
```

## Rollback

```sh
helm history insiderone-devops-case          # find the last good revision
helm rollback insiderone-devops-case <REV>   # or omit <REV> for the previous one
kubectl rollout status deployment/insiderone-devops-case --timeout=2m
curl -s http://<elastic-ip>/version           # confirm the tag reverted
```

## Verify health

```sh
curl -s http://<elastic-ip>/ping        # → pong
curl -s http://<elastic-ip>/version     # → build sha + semver
kubectl get pods -l app.kubernetes.io/name=insiderone-devops-case
kubectl get hpa,ingress,svc
```

## Logs & restart

```sh
# tail structured JSON logs across all replicas
kubectl logs -l app.kubernetes.io/name=insiderone-devops-case --tail=200 -f
# restart cleanly (rolling, zero-downtime via the chart's RollingUpdate)
kubectl rollout restart deployment/insiderone-devops-case
kubectl rollout status  deployment/insiderone-devops-case --timeout=2m
```

Every request line carries `request_id, method, path, status, duration_ms`; grep
a `request_id` to trace one request. `/healthz`, `/readyz`, `/metrics` are logged
at DEBUG to avoid probe noise (raise `LOG_LEVEL=debug` to see them).

## Observability

Monitoring runs on **local minikube** (not EC2 — see ADR `day-4`). Bring it up and
open the dashboards:

```sh
make monitoring-install                  # kube-prometheus-stack in the `monitoring` ns
make monitoring-prometheus               # localhost:9090 — Status/Targets, Alerts
make monitoring-grafana                  # localhost:3000 — import docs/dashboards/insiderone-http.json
```

Grafana admin password:
`kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d`.

Key metrics (from the app's `/metrics`): `http_requests_total{method,route,status}`
and `http_request_duration_seconds`. The dashboard shows RPS, p50/p95 latency, 5xx
error rate, and pod restarts.

Two alert rules ship as a `PrometheusRule`:

**`HighErrorRate`** — 5xx ratio > 5% for 5m (warning):
1. Confirm in Grafana which `route`/`status` is spiking (error-rate panel).
2. Check recent rollouts — `helm history insiderone-devops-case`; if a bad image
   shipped, **roll back** (see Rollback). `helm --atomic` should already have
   reverted a failed deploy.
3. Tail logs (above) for the failing `route` to find the cause.
4. If load-driven, confirm the HPA is scaling: `kubectl get hpa`.

**`AppDown`** — Prometheus can't scrape the app for 2m (critical):
1. `kubectl get pods -l app.kubernetes.io/name=insiderone-devops-case` — are any Ready?
2. Check the Prometheus target (Status → Targets) and the pod's events/logs.
3. If a deploy broke it, roll back; otherwise `kubectl rollout restart` the deployment.

## Common issues

| Symptom | Likely cause | Action |
|---|---|---|
| `/ping` times out, pods Running | host-to-minikube HTTP proxy stale after reboot | `sudo systemctl restart minikube-http-forward` |
| Cluster gone after reboot | minikube didn't restart | `sudo systemctl status minikube`; `sudo systemctl restart minikube` |
| Deploy job: `not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC `sub` / owner-casing mismatch | confirm `AWS_ROLE_ARN` secret + trust policy repo path casing |
| Deploy job: SSM `Failed` | helm/kubectl ran as root, not ec2-user | command must use `runuser -l ec2-user` (see ADR 006) |
| `ImagePullBackOff` | GHCR package not public | make the GHCR package public, or add an imagePullSecret |

## Teardown (stop all AWS billing)

```sh
cd infra/terraform
terraform destroy
```

This releases the Elastic IP, terminates the instance, and removes the OIDC
provider, roles, and security group. Nothing survives to keep billing.
