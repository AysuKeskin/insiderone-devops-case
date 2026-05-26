# Day 3 Architecture Decisions

This file captures the main Day 3 decisions covering CI/CD, supply-chain,
infrastructure, and deploy-time auth.

## ADR 006 - Deploy via SSM Send-Command, no SSH

Status: Accepted

The deploy workflow runs `helm upgrade` on the EC2 host through AWS Systems
Manager Send-Command rather than SSH. SSH would mean storing a long-lived
private key as a GitHub secret, which contradicts the case's "no long-lived
credentials" guidance. With SSM, GitHub Actions assumes an OIDC role and runs a
shell command on the instance using only short-lived credentials, and the
security group can close port 22 entirely.

Two consequences worth noting. Send-Command is asynchronous, so the workflow
polls `ssm:GetCommandInvocation` until the command resolves instead of streaming
output like `ssh -t`. And SSM runs commands as root while the cluster is owned by
`ec2-user` (kubeconfig, docker group), so the deploy command wraps itself in
`runuser -l ec2-user -c '...'` to reach minikube.

## ADR 007 - Helm Upgrade from CI instead of GitOps

Status: Accepted

Deployments are driven by a GitHub Actions workflow that runs
`helm upgrade --install` over SSM, rather than pulling in ArgoCD or Flux.
Adopting a GitOps controller would mean installing and operating another
cluster-side component for a 4-day slice that already has one Deployment and
one Service to manage. The push-from-CI model is simple, observable in the
Actions UI, and aligned with the case's "smallest working slice" guidance.

## ADR 008 - t3.medium over the free-tier t2.micro

Status: Accepted

The EC2 host is a `t3.medium` (4 GB RAM) rather than the free-tier `t2.micro`
(1 GB) or `t3.small` (2 GB). Empirically, minikube + nginx-ingress +
metrics-server + the app cannot run reliably under 2 GB; the kubelet
OOM-kills components during bootstrap and the cluster never reaches Ready.
On `t3.small` the host has no headroom after the OS and Docker, so minikube
is started with 3 GB on `t3.medium` to leave a stable margin. `t3.medium`
costs roughly $30/month if left running, which I accept for a reliable demo.
To keep that cost in check, the Terraform stack is fully `terraform destroy`-able
and the README documents the teardown command, so the host can be shut down
between demo windows.

## ADR 009 - dev = local minikube, prod = EC2; no second cloud environment

Status: Accepted

The case asks for environment-specific config (`values-dev.yaml` vs
`values-prod.yaml` differing on replicas, resources, host). I satisfy that
with the two values files, and map them to where each one is actually used:
`values-dev.yaml` drives the **local** minikube developer loop (`make
rollout-dev`, 1 replica, debug logs) and `values-prod.yaml` is what the CD
pipeline deploys to the **EC2** cluster. I deliberately do not also run a
`dev` release on the same EC2 host: a single node gives no real isolation, so
a second release would be theater rather than a distinct environment, and
prod's `helm upgrade --atomic` already auto-rolls-back a bad image. The dev
values are still exercised — locally and by the `helm lint` job in CI.
