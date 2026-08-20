#!/bin/bash
# Bootstraps the EC2 host for minikube + helm + the app.
# Runs once at first boot via cloud-init. Idempotent: re-running is safe.
#
# Cluster ownership: minikube/kubectl/helm run as ec2-user (kubeconfig in
# /home/ec2-user/.kube, docker group on ec2-user). SSM Send-Command runs as
# root, so the deploy workflow MUST wrap its commands in
# `runuser -l ec2-user -c '...'` to pick up that context. See ADR 006.

set -euxo pipefail

MINIKUBE_VERSION="v1.34.0"
KUBECTL_VERSION="v1.31.0"

# --- packages ----------------------------------------------------------------
dnf update -y
dnf install -y docker git conntrack-tools iptables-services socat tar

systemctl enable --now docker
usermod -aG docker ec2-user

# Wait for the docker socket to actually accept connections before anything
# tries to use it (cloud-init can outrun dockerd's first start).
timeout 90 bash -c 'until docker info >/dev/null 2>&1; do sleep 2; done'

# --- kubectl -----------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  curl -L "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi

# --- helm --------------------------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- minikube ----------------------------------------------------------------
if ! command -v minikube >/dev/null 2>&1; then
  curl -L "https://github.com/kubernetes/minikube/releases/download/$${MINIKUBE_VERSION}/minikube-linux-amd64" -o /usr/local/bin/minikube
  chmod +x /usr/local/bin/minikube
fi

# --- app repo (public, no auth) ---------------------------------------------
APP_DIR=/opt/app
if [ ! -d "$APP_DIR/.git" ]; then
  git clone "https://github.com/${github_owner}/${github_repo}.git" "$APP_DIR"
else
  git -C "$APP_DIR" pull --ff-only || true
fi
chown -R ec2-user:ec2-user "$APP_DIR"

# --- minikube as a systemd service (survives reboots) -----------------------
# Running as ec2-user keeps the cluster owned by one identity; RemainAfterExit
# keeps the oneshot "active" so the forward unit can order after it.
cat > /etc/systemd/system/minikube.service <<'EOF'
[Unit]
Description=minikube single-node cluster
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=ec2-user
Environment=HOME=/home/ec2-user
ExecStart=/usr/local/bin/minikube start --driver=docker --cpus=2 --memory=3000
ExecStop=/usr/local/bin/minikube stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minikube.service

# Enable addons once; they persist in the minikube profile and come back on
# every `minikube start`, so this does not need to repeat on reboot.
sudo -u ec2-user -H /usr/local/bin/minikube addons enable ingress
sudo -u ec2-user -H /usr/local/bin/minikube addons enable metrics-server

# --- expose host port 80 through the minikube ingress ------------------------
# A small TCP proxy is simpler and less fragile than DNAT/FORWARD rules on an
# EC2 host running Docker-managed bridge networks.
cat > /usr/local/sbin/minikube-http-forward.sh <<'EOF'
#!/bin/bash
set -euo pipefail
MINIKUBE_IP="$(runuser -l ec2-user -c 'minikube ip')"
exec /usr/bin/socat TCP-LISTEN:80,fork,reuseaddr TCP:"$MINIKUBE_IP":80
EOF
chmod +x /usr/local/sbin/minikube-http-forward.sh

cat > /etc/systemd/system/minikube-http-forward.service <<'EOF'
[Unit]
Description=Proxy host port 80 to minikube ingress
After=minikube.service
Requires=minikube.service

[Service]
Restart=always
RestartSec=3
ExecStart=/usr/local/sbin/minikube-http-forward.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minikube-http-forward.service

# --- expose host port 443 through the minikube ingress (for TLS) -------------
# Mirrors the :80 proxy; the ingress terminates TLS at :443 once cert-manager
# has issued a certificate. Harmless when TLS is not configured yet.
cat > /usr/local/sbin/minikube-https-forward.sh <<'EOF'
#!/bin/bash
set -euo pipefail
MINIKUBE_IP="$(runuser -l ec2-user -c 'minikube ip')"
exec /usr/bin/socat TCP-LISTEN:443,fork,reuseaddr TCP:"$MINIKUBE_IP":443
EOF
chmod +x /usr/local/sbin/minikube-https-forward.sh

cat > /etc/systemd/system/minikube-https-forward.service <<'EOF'
[Unit]
Description=Proxy host port 443 to minikube ingress
After=minikube.service
Requires=minikube.service

[Service]
Restart=always
RestartSec=3
ExecStart=/usr/local/sbin/minikube-https-forward.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minikube-https-forward.service

echo "bootstrap complete: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /var/log/bootstrap-done
