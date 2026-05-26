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
- **Public URL**: `https://devops-case.aysu-keskin.uk/` (Cloudflare → Elastic IP → ingress; the raw IP also answers over HTTP via a catch-all rule).

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

**Local minikube** — one command (rolls back to the previous revision and waits):

```sh
make rollback
curl -s localhost:8080/version   # confirm the tag reverted
```

**Prod (EC2)** — there is no direct cluster access from a laptop, so run it on the
box via SSM as `ec2-user`:

```sh
# 1) on your machine — get the instance id (or read it from the AWS console):
terraform -chdir=infra/terraform output -raw ec2_instance_id

# 2) open a shell on the box:
aws ssm start-session --target <instance-id> --region eu-north-1

# 3) inside the session (runs as ec2-user, the cluster owner):
sudo runuser -l ec2-user -c "helm history insiderone-devops-case"          # find the last good revision
sudo runuser -l ec2-user -c "helm rollback insiderone-devops-case && kubectl rollout status deployment/insiderone-devops-case --timeout=2m"
exit                                                                       # leave the SSM session

# 4) confirm from anywhere:
curl -s https://devops-case.aysu-keskin.uk/version               # the tag reverted
```

To target a specific revision instead of the previous one:
`helm rollback insiderone-devops-case <REV>`.

## Verify health

```sh
curl -s https://devops-case.aysu-keskin.uk/ping        # → pong
curl -s https://devops-case.aysu-keskin.uk/version     # → build sha + semver
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

## Secret rotation

**App secret** (Helm-managed `insiderone-devops-case-secret`) — update the value and
re-deploy; the chart's `checksum/secret` annotation rolls the pods automatically so
the new value takes effect:

```sh
helm upgrade --install insiderone-devops-case helm/insiderone-devops-case \
  -f helm/insiderone-devops-case/values-prod.yaml \
  --set-string secret.stringData.<KEY>=<NEW_VALUE>
# (or update it from your secret manager, then) kubectl rollout restart deploy/insiderone-devops-case
```

**Cloudflare API token** (`cloudflare-api-token` in the `cert-manager` namespace,
used for the DNS-01 challenge) — revoke the old token in Cloudflare, create a new one
(scopes: Zone:DNS:Edit + Zone:Read), then replace the secret:

```sh
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token=<NEW_TOKEN> --dry-run=client -o yaml | kubectl apply -f -
```
cert-manager picks it up on the next renewal; no pod restart needed.

**AWS / GHCR** — nothing to rotate: CI authenticates to AWS via short-lived GitHub
OIDC tokens (no stored access keys) and to GHCR via the ephemeral `GITHUB_TOKEN`.

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

## TLS / HTTPS (custom domain via cert-manager + Cloudflare)

`values-prod.yaml` carries the domain + TLS (cert-manager issues the cert; the
chart also keeps a catch-all rule so the raw IP still answers over HTTP). The
cluster needs this one-time setup before a prod deploy can serve HTTPS:

1. **Cloudflare** — add a DNS `A` record `devops-case.aysu-keskin.uk` → the
   Elastic IP. Create an API token scoped to `Zone:DNS:Edit` for the zone.
2. **cert-manager** — `make tls-install`.
3. **Cloudflare token secret** (cert-manager namespace):
   ```sh
   kubectl create secret generic cloudflare-api-token -n cert-manager \
     --from-literal=api-token='<TOKEN>'
   ```
4. **Issuer** — set the email in `deploy/tls/clusterissuer.yaml`, then
   `kubectl apply -f deploy/tls/clusterissuer.yaml`.
5. **443 forward** — fresh EC2 instances get it from `user_data` (socat 443→minikube);
   on an existing box, add `minikube-https-forward.service` (mirror of the :80 one).
6. **Deploy** (CI/CD does this automatically with `values-prod.yaml`):
   ```sh
   helm upgrade --install insiderone-devops-case helm/insiderone-devops-case \
     -f helm/insiderone-devops-case/values-prod.yaml
   ```
7. **Wait for the cert** — `kubectl get certificate`; `kubectl describe certificate
   insiderone-devops-case-tls` to debug a `False` Ready.
8. **Cloudflare** — proxy ON (orange cloud), SSL/TLS mode **Full (strict)**.
9. **Test** — `curl -I https://devops-case.aysu-keskin.uk/ping` → `200`.

If issuance is stuck: check `kubectl get challenges,orders -A`, the
`cloudflare-api-token` secret, and that the issuer email is real.

## Common issues

| Symptom | Likely cause | Action |
|---|---|---|
| `/ping` times out, pods Running | host-to-minikube HTTP proxy stale after reboot | `sudo systemctl restart minikube-http-forward` |
| HTTPS fails but HTTP works | `:443` forward down, or cert not Ready | `sudo systemctl status minikube-https-forward`; `kubectl get certificate` |
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
