# Day 3 Architecture Decisions

This file captures the main Day 3 decisions covering CI/CD, supply-chain,
infrastructure, and deploy-time auth.

## ADR 006 - Deploy via SSM Send-Command, no SSH

Status: Accepted

The deploy workflow runs `helm upgrade` on the EC2 host through AWS Systems
Manager Send-Command rather than SSH. SSH would require storing a long-lived
private key as a GitHub secret, which directly contradicts the case's
"no long-lived credentials" guidance. SSM lets GitHub Actions assume an OIDC
role and trigger a shell command on the instance using only short-lived
credentials; the security group can also close port 22 entirely, shrinking
the public attack surface. Tradeoff: Send-Command is asynchronous and harder
to stream output from than `ssh -t`, so the workflow polls
`ssm:GetCommandInvocation` until the command resolves. One operational
consequence: SSM runs commands as root, but the cluster is owned by
`ec2-user` (kubeconfig and docker group), so the deploy command must wrap
itself in `runuser -l ec2-user -c '...'` to reach minikube.

## ADR 007 - Helm Upgrade from CI instead of GitOps

Status: Accepted

Deployments are driven by a GitHub Actions workflow that runs
`helm upgrade --install` over SSM, rather than pulling in ArgoCD or Flux.
Adopting a GitOps controller would mean installing and operating another
cluster-side component for a 4-day slice that already has one Deployment and
one Service to manage. The push-from-CI model is simple, observable in the
Actions UI, and aligned with the case's "smallest working slice" guidance.
The natural next iteration would be Flux plus image-automation, watching the
GHCR digest written by the CI job; this ADR documents that direction without
adopting it yet.

## ADR 008 - t3.medium over the free-tier t2.micro

Status: Accepted

The EC2 host is a `t3.medium` (4 GB RAM) rather than the free-tier `t2.micro`
(1 GB) or `t3.small` (2 GB). Empirically, minikube + nginx-ingress +
metrics-server + the app cannot run reliably under 2 GB; the kubelet
OOM-kills components during bootstrap and the cluster never reaches Ready.
On `t3.small` the host has no headroom after the OS and Docker, so minikube
is started with 3 GB on `t3.medium` to leave a stable margin. `t3.medium`
costs roughly $30/month if left running, which we accept for a reliable demo.
Cost mitigation: the Terraform stack is fully `terraform destroy`-able and
the README documents the teardown command so the host can be shut down
between demo windows.

## ADR 009 - dev = local minikube, prod = EC2; no second cloud environment

Status: Accepted

The case asks for environment-specific config (`values-dev.yaml` vs
`values-prod.yaml` differing on replicas, resources, host). We satisfy that
with the two values files, and map them to where each one is actually used:
`values-dev.yaml` drives the **local** minikube developer loop (`make
rollout-dev`, 1 replica, debug logs) and `values-prod.yaml` is what the CD
pipeline deploys to the **EC2** cluster. We deliberately do not also run a
`dev` release on the same EC2 host: a single node gives no real isolation, so
a second release would be theater rather than a distinct environment, and
prod's `helm upgrade --atomic` already auto-rolls-back a bad image. A genuine
cloud dev environment would be a separate cluster (or a manual approval gate
between stages); both are out of scope for this single-node slice. The dev
values are still exercised — locally and by the `helm lint` job in CI.
