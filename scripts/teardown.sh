#!/usr/bin/env bash
# kind クラスタごと丸ごと削除する。PVCの中身も消える。
set -euo pipefail

CLUSTER_NAME="marimo"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[+] kind cluster '${CLUSTER_NAME}' を削除..."
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "[=] kind cluster '${CLUSTER_NAME}' は存在しません。"
fi
