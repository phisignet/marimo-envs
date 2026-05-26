#!/usr/bin/env bash
# kind クラスタを丸ごと削除する。PVC の中身(ノートブックファイル等)も消える。
# Step / Agent に依らず共通(同じクラスタ名 `marimo` を使うため)。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

CLUSTER_NAME="marimo"

require_command kind "scripts/install-tools.sh で導入してください。"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "[+] kind cluster '${CLUSTER_NAME}' を削除..."
    kind delete cluster --name "$CLUSTER_NAME"
else
    echo "[=] kind cluster '${CLUSTER_NAME}' は存在しません。スキップ。"
fi
