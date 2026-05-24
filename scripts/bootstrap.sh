#!/usr/bin/env bash
# Step 1(1人での試用)用のワンショットbootstrap。
# 推論バックエンドは Ollama(本ブランチ feat/codex-ollama)。
# - kindクラスタを起動(なければ)
# - marimo拡張イメージと codex-acp イメージをビルドして kind に load
# - ConfigMap(Ollama接続情報)を apply
# - マニフェスト一式を apply
# - 起動を待ってアクセスURLを表示
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLUSTER_NAME="marimo"
NS="marimo"
KCTX="kind-${CLUSTER_NAME}"

# Image タグは manifests/step1/ を single source of truth として扱う。
extract_image() {
  { grep -REh "^[[:space:]]+image:[[:space:]]+$1" manifests/step1/ \
      | head -1 | awk '{print $2}'; } || true
}
MARIMO_IMAGE="$(extract_image 'marimo-envs/marimo:')"
ACP_IMAGE="$(extract_image   'marimo-envs/codex-acp:')"

if [[ -z "$MARIMO_IMAGE" || -z "$ACP_IMAGE" ]]; then
  echo "ERROR: manifests/step1/ から marimo / codex-acp の image タグを抽出できませんでした。" >&2
  exit 1
fi
echo "[=] images from manifests/step1/:"
echo "    MARIMO_IMAGE=${MARIMO_IMAGE}"
echo "    ACP_IMAGE   =${ACP_IMAGE}"

# -------- 前提チェック --------
for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool が見つかりません。'scripts/install-tools.sh' を先に実行してください。" >&2
    exit 1
  fi
done

# Ollama エンドポイントは必須。host の Ollama に Pod から到達する URL。
# 例: http://192.168.64.32:11434/v1
if [[ -z "${OLLAMA_BASE_URL:-}" ]]; then
  # 未指定なら hostname -I の LAN IPv4 で自動推測する。
  AUTO_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    | grep -v -E '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
    | head -1)"
  if [[ -n "$AUTO_IP" ]]; then
    OLLAMA_BASE_URL="http://${AUTO_IP}:11434/v1"
    echo "[=] OLLAMA_BASE_URL 未指定 → 自動推測: ${OLLAMA_BASE_URL}"
  else
    cat >&2 <<'EOF'
ERROR: 環境変数 OLLAMA_BASE_URL が未設定で、自動推測も失敗しました。

  Pod から host の Ollama に到達できる URL を指定してください。
  Ollama は OLLAMA_HOST=0.0.0.0:11434 で listen している必要があります。

  例:
    export OLLAMA_BASE_URL='http://192.168.64.32:11434/v1'
    ./scripts/bootstrap.sh
EOF
    exit 1
  fi
fi

CODEX_MODEL="${CODEX_MODEL:-gemma4:31b-cloud}"
CODEX_WIRE_API="${CODEX_WIRE_API:-responses}"
echo "[=] Codex 設定:"
echo "    OLLAMA_BASE_URL=${OLLAMA_BASE_URL}"
echo "    CODEX_MODEL    =${CODEX_MODEL}"
echo "    CODEX_WIRE_API =${CODEX_WIRE_API}"

# -------- kindクラスタ --------
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[=] kind cluster '${CLUSTER_NAME}' は既に存在します。スキップ。"
  # Step 1(Codex)が必要とする extraPortMappings (30718, 30321) を検証。
  node_container="${CLUSTER_NAME}-control-plane"
  missing=()
  for p in 30718 30321; do
    if ! docker port "$node_container" "${p}/tcp" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    cat >&2 <<EOF
ERROR: 既存の kind クラスタ '${CLUSTER_NAME}' に Step 1 (Codex) が必要な
       ポートマッピングがありません(欠落: ${missing[*]})。
       Claude 用や Step 4 用の cluster 設定で作られた可能性があります。
       teardown して再作成してください:

           ./scripts/teardown.sh   # クラスタ削除
           ./scripts/bootstrap.sh  # Step 1 (Codex) 用設定で再作成
EOF
    exit 1
  fi
else
  echo "[+] kind cluster '${CLUSTER_NAME}' を作成 (Step 1 Codex 設定: 2718/3021 を bind)..."
  kind create cluster --name "$CLUSTER_NAME" --config kind/cluster-step1.yaml
fi

# -------- カスタムイメージ群 --------
echo "[+] marimo拡張イメージ(marimo[mcp]入り)をビルド: ${MARIMO_IMAGE}"
docker build -t "$MARIMO_IMAGE" images/marimo

echo "[+] Codex ACPサイドカーイメージをビルド: ${ACP_IMAGE}"
docker build -t "$ACP_IMAGE" images/codex-acp

echo "[+] 両イメージをkindクラスタにload..."
kind load docker-image "$MARIMO_IMAGE" --name "$CLUSTER_NAME"
kind load docker-image "$ACP_IMAGE"    --name "$CLUSTER_NAME"

# -------- マニフェスト適用 --------
echo "[+] Namespace と PVC を適用..."
kubectl --context "$KCTX" apply -f manifests/namespace.yaml
kubectl --context "$KCTX" apply -f manifests/step1/pvc.yaml

echo "[+] Codex 接続用 ConfigMap を作成/更新..."
kubectl --context "$KCTX" -n "$NS" create configmap codex-config \
  --from-literal=ollama_base_url="$OLLAMA_BASE_URL" \
  --from-literal=model="$CODEX_MODEL" \
  --from-literal=wire_api="$CODEX_WIRE_API" \
  --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f -

echo "[+] Deployment と Service を適用..."
kubectl --context "$KCTX" apply -f manifests/step1/deployment.yaml
kubectl --context "$KCTX" apply -f manifests/step1/service.yaml

# ConfigMap 更新を確実に反映するため毎回 rollout restart。
echo "[+] Pod を rollout restart (新 ConfigMap を読ませる)..."
kubectl --context "$KCTX" -n "$NS" rollout restart deployment/marimo

echo "[+] marimo Deployment の rollout を待機..."
kubectl --context "$KCTX" -n "$NS" rollout status deployment/marimo --timeout=300s

# -------- アクセス情報 --------
if [[ -z "${LAN_IP:-}" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    | grep -v -E '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
    | head -1)"
fi
if [[ -z "${LAN_IP:-}" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    | head -1)"
fi

cat <<EOF

====================================================================
 marimo + Codex ACP は起動しました(推論: Ollama via ${CODEX_MODEL})。

 このマシンから:
   http://localhost:2718/

EOF
if [[ -n "${LAN_IP}" ]]; then
  cat <<EOF
 同じLAN上の他PCから:
   http://${LAN_IP}:2718/

EOF
fi
cat <<EOF
 marimo UI を開いたら:
   1. Settings (右上歯車) → Lab → "agents" を有効化
   2. 左サイドバーのエージェントアイコンをクリック
   3. ドロップダウンから "Codex" を選択
   4. ブラウザは ws://<同じホスト>:3021/message に自動接続します

 状態確認(current context が別クラスタの可能性に備えて --context を明示):
   kubectl --context ${KCTX} -n ${NS} get pods,svc
   kubectl --context ${KCTX} -n ${NS} logs deploy/marimo -c marimo
   kubectl --context ${KCTX} -n ${NS} logs deploy/marimo -c codex-acp

 Codex から Ollama への到達確認:
   kubectl --context ${KCTX} -n ${NS} exec deploy/marimo -c codex-acp -- \\
     sh -c "wget -qO- \${OLLAMA_BASE_URL}/models 2>/dev/null || echo 'wget無し→ログ確認'"

 後片付け:
   ./scripts/teardown.sh
====================================================================
EOF
