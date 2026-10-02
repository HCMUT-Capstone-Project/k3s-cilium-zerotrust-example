#!/usr/bin/env bash
# Cài K3s (không flannel/kube-proxy) + Cilium (kubeProxyReplacement + WireGuard + L7)
# Chạy BÊN TRONG Ubuntu WSL2:  bash scripts/install-k3s-cilium.sh
# Chạy lại an toàn: tự bỏ qua các bước đã xong.
set -euo pipefail

K3S_EXEC="--flannel-backend=none --disable-network-policy --disable-kube-proxy --disable servicelb --disable traefik --write-kubeconfig-mode 644"
CILIUM_VERSION="v0.20.1"
ARCH="$(dpkg --print-architecture)" # amd64 / arm64

echo "==> [1/5] deps"
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates iptables wireguard-tools

echo "==> [2/5] k3s"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${K3S_EXEC}" sh -
else
  echo "k3s already installed, skipping"
fi
mkdir -p ~/.kube
sudo cp -f /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
export KUBECONFIG=~/.kube/config
kubectl wait --for=condition=Ready nodes --all --timeout=180s || true
kubectl get nodes -o wide

echo "==> [3/5] helm"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version

echo "==> [4/5] cilium CLI (${CILIUM_VERSION}/${ARCH})"
if ! command -v cilium >/dev/null 2>&1; then
  curl -fsSL -o /tmp/cilium.tar.gz "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_VERSION}/cilium-linux-${ARCH}.tar.gz"
  sudo tar -xzf /tmp/cilium.tar.gz -C /usr/local/bin
  rm -f /tmp/cilium.tar.gz
fi
cilium version || true

echo "==> [5/5] cilium install"
export KUBECONFIG=~/.kube/config
if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  echo "cilium already present, upgrading settings"
fi
sudo -E cilium install \
  --set kubeProxyReplacement=true \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set l7Proxy=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

cilium status --wait
kubectl -n kube-system get pods -o wide
echo "OK: kubeconfig at ~/.kube/config"
