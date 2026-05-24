#!/usr/bin/env bash
# Step 4 PoC: 1台のサーバー上で nb1, nb2 の2環境を並行運用し、
# nginx Hostヘッダ振り分け + nip.io ワイルドカードDNSで分流する。
#
# 前提:
#   - scripts/install-tools.sh で kind/kubectl 導入済み
#   - claude setup-token で取得した OAuth トークンを env で渡す
#   - LAN到達可能なIPがホストに存在する(hostname -I で確認)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLUSTER_NAME="marimo"
NS="marimo"

# image タグは step4 マニフェストを single source of truth に。
extract_image() {
  { grep -REh "^[[:space:]]+image:[[:space:]]+$1" manifests/step4/ \
      | head -1 | awk '{print $2}'; } || true
}
MARIMO_IMAGE="$(extract_image 'marimo-envs/marimo:')"
ACP_IMAGE="$(extract_image   'marimo-envs/acp-agent:')"

if [[ -z "$MARIMO_IMAGE" || -z "$ACP_IMAGE" ]]; then
  echo "ERROR: step4 マニフェストから image を抽出できませんでした。" >&2
  exit 1
fi
echo "[=] images:"
echo "    MARIMO_IMAGE=${MARIMO_IMAGE}"
echo "    ACP_IMAGE   =${ACP_IMAGE}"

# -------- 前提チェック --------
for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool が見つかりません。scripts/install-tools.sh を実行してください。" >&2
    exit 1
  fi
done

if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: 環境変数 CLAUDE_CODE_OAUTH_TOKEN が未設定です。
  手元の端末で `claude setup-token` を実行し、出力された長いトークンを
  export CLAUDE_CODE_OAUTH_TOKEN='<...>' してから再実行してください。
EOF
  exit 1
fi

# 公開IPの取得(LAN第1IPv4)
LAN_IP="$(hostname -I | awk '{print $1}')"
if [[ -z "$LAN_IP" ]]; then
  echo "ERROR: LAN IP を取得できませんでした(hostname -I が空)。" >&2
  exit 1
fi
echo "[=] LAN_IP=${LAN_IP}"

# Port 80 は通常 root 必要だが、kind が docker 経由でバインドするため
# docker daemon が root 権限を持っていれば一般ユーザーで OK。
# 失敗時は ss -tlnp で既存LISTENを確認。
echo "[+] ホスト側 80 ポートが空いているか念のため確認..."
if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)80$'; then
  echo "  WARN: 既に :80 が LISTEN 中の可能性があります。bootstrap が失敗したら確認を。" >&2
fi

# -------- kind クラスタ --------
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[=] kind cluster '${CLUSTER_NAME}' は既に存在します。スキップ。"
else
  echo "[+] kind cluster '${CLUSTER_NAME}' を作成..."
  kind create cluster --name "$CLUSTER_NAME" --config kind/cluster.yaml
fi

# -------- カスタムイメージ --------
echo "[+] marimo拡張イメージをビルド: ${MARIMO_IMAGE}"
docker build -t "$MARIMO_IMAGE" images/marimo
echo "[+] ACPサイドカーイメージをビルド: ${ACP_IMAGE}"
docker build -t "$ACP_IMAGE" images/acp-agent

echo "[+] kindにload..."
kind load docker-image "$MARIMO_IMAGE" --name "$CLUSTER_NAME"
kind load docker-image "$ACP_IMAGE"    --name "$CLUSTER_NAME"

# -------- マニフェスト適用 --------
echo "[+] Namespace と Secret..."
kubectl apply -f manifests/namespace.yaml
kubectl -n "$NS" create secret generic claude-code-token \
  --from-literal=token="$CLAUDE_CODE_OAUTH_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[+] nginx (ConfigMap + Deployment + Service)..."
kubectl apply -f manifests/step4/nginx-configmap.yaml
kubectl apply -f manifests/step4/nginx-deployment.yaml

echo "[+] notebook 環境 nb1 / nb2..."
kubectl apply -f manifests/step4/notebook-nb1.yaml
kubectl apply -f manifests/step4/notebook-nb2.yaml

# Secret更新時もPodに反映されるよう常にrestart
echo "[+] 全 Deployment を rollout restart (新Secretを確実に読ませる)..."
kubectl -n "$NS" rollout restart deploy/nginx-gateway deploy/marimo-nb1 deploy/marimo-nb2

echo "[+] 起動待ち(各 Deployment ≤300s)..."
kubectl -n "$NS" rollout status deploy/nginx-gateway --timeout=120s
kubectl -n "$NS" rollout status deploy/marimo-nb1    --timeout=300s
kubectl -n "$NS" rollout status deploy/marimo-nb2    --timeout=300s

cat <<EOF

====================================================================
 Step 4 PoC は起動しました。

 アクセスURL(同じLAN上のどの端末からでも):
   nb1: http://nb1.${LAN_IP}.nip.io/
   nb2: http://nb2.${LAN_IP}.nip.io/

 marimo UIで:
   1. Settings → Lab → "agents" を有効化(初回のみ。各ホストごとに必要)
   2. 左サイドバーのエージェントアイコン
   3. "Claude" を選択 → ブラウザは ws://<同じホスト名>:3017/message に
      自動接続(nginx が Hostヘッダで該当 Pod に流す)

 状態確認:
   kubectl -n marimo get pods,svc
   kubectl -n marimo logs deploy/nginx-gateway
   kubectl -n marimo logs deploy/marimo-nb1 -c marimo
   kubectl -n marimo logs deploy/marimo-nb2 -c acp-agent

 後片付け:
   ./scripts/teardown.sh
====================================================================
EOF
