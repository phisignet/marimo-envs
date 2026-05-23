#!/usr/bin/env bash
# kind と kubectl を ~/.local/bin に sudo なしで導入する。
# 既にインストール済みなら何もしない。
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

case ":$PATH:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "WARN: ${BIN_DIR} が PATH に含まれていない。シェル設定で追加してください。" >&2 ;;
esac

KIND_VERSION="${KIND_VERSION:-v0.24.0}"

if command -v kind >/dev/null 2>&1; then
  echo "[=] kind already installed: $(kind version 2>/dev/null | head -1)"
else
  echo "[+] Installing kind ${KIND_VERSION} → ${BIN_DIR}/kind"
  curl -fsSL -o "${BIN_DIR}/kind" \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  chmod +x "${BIN_DIR}/kind"
fi

if command -v kubectl >/dev/null 2>&1; then
  echo "[=] kubectl already installed: $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1)"
else
  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  echo "[+] Installing kubectl ${KUBECTL_VERSION} → ${BIN_DIR}/kubectl"
  curl -fsSL -o "${BIN_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x "${BIN_DIR}/kubectl"
fi

echo "[ok] tools ready."
