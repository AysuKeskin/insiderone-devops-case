#!/bin/bash
# Bootstraps the EC2 host for minikube + helm + the case-study app.
# Runs once at first boot via cloud-init. Idempotent: re-running is safe.

set -euxo pipefail

# --- packages ----------------------------------------------------------------
dnf update -y
dnf install -y docker git conntrack-tools iptables-services tar

systemctl enable --now docker
usermod -aG docker ec2-user

# --- kubectl -----------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  curl -L "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi

# --- helm --------------------------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- minikube ----------------------------------------------------------------
if ! command -v minikube >/dev/null 2>&1; then
  curl -L "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64" -o /usr/local/bin/minikube
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

# --- minikube as ec2-user ----------------------------------------------------
# Docker group membership only takes effect on next login; use sg to pick it
# up inside this cloud-init shell without rebooting.
sudo -u ec2-user -H bash -lc '
  set -euxo pipefail
  sg docker -c "minikube status >/dev/null 2>&1 || minikube start --driver=docker --cpus=2 --memory=3000"
  sg docker -c "minikube addons enable ingress"
  sg docker -c "minikube addons enable metrics-server"
'

# --- forward host 80/443 to the minikube ingress LoadBalancer ----------------
# minikube ingress lives on the minikube VM IP; expose it on the host
# interface so the Elastic IP reaches it without a tunnel.
MINIKUBE_IP="$(sudo -u ec2-user -H bash -lc 'sg docker -c "minikube ip"')"
echo "MINIKUBE_IP=$MINIKUBE_IP" > /etc/default/minikube-ip

cat > /etc/systemd/system/minikube-ingress-forward.service <<'EOF'
[Unit]
Description=Forward host 80/443 to minikube ingress
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/default/minikube-ip
ExecStart=/usr/bin/bash -c 'sysctl -w net.ipv4.ip_forward=1; iptables -t nat -C PREROUTING -p tcp --dport 80 -j DNAT --to-destination $MINIKUBE_IP:80 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $MINIKUBE_IP:80; iptables -t nat -C PREROUTING -p tcp --dport 443 -j DNAT --to-destination $MINIKUBE_IP:443 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination $MINIKUBE_IP:443; iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minikube-ingress-forward.service

echo "bootstrap complete: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /var/log/bootstrap-done
