# Runbook

Operational guide for the `insiderone-devops-case` service running on minikube
on EC2. Alerting and dashboard sections are added in Day 4.

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
