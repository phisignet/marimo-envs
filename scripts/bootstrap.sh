#!/usr/bin/env bash
# Step 1(1人での試用)用のワンショットbootstrap(Codex+Ollama 構成)。
# 推論バックエンドは Ollama(OpenAI互換 API)、エージェントは Codex CLI。
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
for tool in docker kind kubectl curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      docker|kind|kubectl)
        echo "ERROR: $tool が見つかりません。'scripts/install-tools.sh' を先に実行してください。" >&2
        ;;
      curl)
        echo "ERROR: curl が見つかりません。codex-catalog 生成時に Ollama /api/show を叩くために必須です。" >&2
        ;;
      python3)
        echo "ERROR: python3 が見つかりません。/api/show の JSON から model.json を組み立てるために必須です。" >&2
        ;;
    esac
    exit 1
  fi
done

# Ollama エンドポイントは必須。host の Ollama に Pod から到達する URL。
# 例: http://192.168.64.32:11434/v1
if [[ -z "${OLLAMA_BASE_URL:-}" ]]; then
  # 未指定なら hostname -I の LAN IPv4 で自動推測する。
  # 1段目: 192.168.x.x / 10.x.x.x など「家庭/社内 LAN らしい」レンジ優先で、
  #        docker bridge 系(172.16-31.x.x)と loopback (127.x.x.x) は除外。
  AUTO_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    | grep -v -E '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
    | head -1)"
  # 2段目: 1段目で見つからない=社内LANが 172.* 帯の可能性。
  # 除外を緩めて loopback だけ外して再試行(docker bridge を誤選択する可能性あり、
  # 警告を出して LAN_IP 明示指定を促す)。
  if [[ -z "$AUTO_IP" ]]; then
    AUTO_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
      | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
      | grep -v -E '^127\.' \
      | head -1)"
    if [[ -n "$AUTO_IP" ]]; then
      echo "  WARN: 192.168.x.x / 10.x.x.x が見つからず、172.x.x.x の AUTO_IP=${AUTO_IP}" >&2
      echo "        を選択。docker/kind の bridge ネットワークの可能性があります。" >&2
      echo "        意図と違う場合は OLLAMA_BASE_URL を手動指定してください:" >&2
      echo "          export OLLAMA_BASE_URL='http://<実際のLAN_IP>:11434/v1'" >&2
    fi
  fi
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

# OLLAMA_BASE_URL の入力正規化: 末尾スラッシュ除去 + /v1 サフィックス保証。
# これにより以下のすべての入力を同等扱いにする:
#   http://x.x.x.x:11434  / http://x.x.x.x:11434/  / http://x.x.x.x:11434/v1  / http://x.x.x.x:11434/v1/
# 後段の OLLAMA_API_SHOW_URL 組み立て(${url%/v1}/api/show)で `//api/show` に
# ならないようにするため必須。
OLLAMA_BASE_URL="${OLLAMA_BASE_URL%/}"
case "$OLLAMA_BASE_URL" in
  */v1) ;;  # 既に /v1 で終わる、何もしない
  *)    OLLAMA_BASE_URL="${OLLAMA_BASE_URL}/v1" ;;
esac

CODEX_MODEL="${CODEX_MODEL:-gemma4:31b-cloud}"
echo "[=] Codex 設定:"
echo "    OLLAMA_BASE_URL=${OLLAMA_BASE_URL}"
echo "    CODEX_MODEL    =${CODEX_MODEL}"
# 注: wire_api は本構成では明示せず Codex CLI のデフォルト("responses")に任せる
# (Ollama 公式の Codex 統合形式に準拠)。env での切替機能は不要なため非対応。

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
  --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f -

# codex-catalog: Codex CLI の「Model metadata for X not found」警告を抑制する
# model.json を ConfigMap 化して Pod に注入する(deployment.yaml で必須参照)。
# 内容は Ollama /api/show の出力 (context_length, capabilities) を元に、
# Codex の buildCodexModelEntry (cmd/launch/codex.go) と同じフィールド構造で
# 動的組み立てする。モデル変更時も bootstrap 再実行で自動追従。
echo "[+] codex-catalog ConfigMap(model.json)を Ollama /api/show から動的生成..."
# /api/show は /api/ 系(OpenAI互換ではない)。OLLAMA_BASE_URL の /v1 を /api/show に置換
OLLAMA_API_SHOW_URL="${OLLAMA_BASE_URL%/v1}/api/show"
CATALOG_TMP="$(mktemp -d)/model.json"
trap 'rm -rf "$(dirname "$CATALOG_TMP")"' EXIT

# curl の stderr は捨てない(失敗時の診断: 接続失敗、HTTPステータス、TLS エラー等を見せる)。
SHOW_JSON="$(dirname "$CATALOG_TMP")/api-show.json"
SHOW_ERR="$(dirname "$CATALOG_TMP")/api-show.err"

# JSON ペイロードは Python の json.dumps で安全にエスケープして組み立てる。
# CODEX_MODEL に " や \ や改行が含まれていても curl -d が壊れない。
SHOW_PAYLOAD=$(CODEX_MODEL="$CODEX_MODEL" python3 -c \
  'import json, os; print(json.dumps({"name": os.environ["CODEX_MODEL"]}))')

if ! curl -fsS -X POST "$OLLAMA_API_SHOW_URL" \
    -H 'Content-Type: application/json' \
    -d "$SHOW_PAYLOAD" \
    -o "$SHOW_JSON" 2>"$SHOW_ERR"; then
  echo "ERROR: Ollama /api/show 呼び出し失敗。Ollama が ${OLLAMA_API_SHOW_URL} で" >&2
  echo "       到達可能でモデル '${CODEX_MODEL}' が pull 済みであることを確認してください。" >&2
  echo "  curl stderr:" >&2
  sed 's/^/    /' "$SHOW_ERR" >&2
  if [[ -s "$SHOW_JSON" ]]; then
    echo "  応答内容(先頭5行):" >&2
    head -5 "$SHOW_JSON" | sed 's/^/    /' >&2
  fi
  exit 1
fi

# Python で /api/show の応答から model.json を組み立てる。
# 取得項目:
#   - model_info.<family>.context_length(モデルのコンテキスト窓)
#   - capabilities(vision あれば input_modalities に image 追加)
# -cloud サフィックス付きモデルは truncation mode を tokens に。
#
# heredoc は <<'PYEOF' とクォートして Python ソースのシェル展開を抑止。
# 引数(モデル名、show応答パス)は env 経由で渡す(" や \ が含まれていても安全)。
SHOW_JSON_PATH="$SHOW_JSON" \
CODEX_MODEL="$CODEX_MODEL" \
python3 <<'PYEOF' > "$CATALOG_TMP"
import json, os
with open(os.environ["SHOW_JSON_PATH"]) as f:
    show = json.load(f)
model_name = os.environ["CODEX_MODEL"]
# context_length は model_info.<family>.context_length に入る(family は様々)
ctx_len = 128_000  # fallback
for k, v in (show.get("model_info") or {}).items():
    if k.endswith(".context_length") and isinstance(v, int):
        ctx_len = v
        break
caps = show.get("capabilities") or []
modalities = ["text"] + (["image"] if "vision" in caps else [])
# -cloud モデルは Codex 内部で truncation mode が tokens 扱いされる
truncation_mode = "tokens" if model_name.endswith("-cloud") else "bytes"
entry = {
    "slug": model_name,
    "display_name": model_name,
    "context_window": ctx_len,
    "shell_type": "default",
    "visibility": "list",
    "supported_in_api": True,
    "priority": 0,
    "truncation_policy": {"mode": truncation_mode, "limit": 10000},
    "input_modalities": modalities,
    "base_instructions": "",
    "support_verbosity": True,
    "default_verbosity": "low",
    "supports_parallel_tool_calls": False,
    "supports_reasoning_summaries": False,
    "supported_reasoning_levels": [],
    "experimental_supported_tools": [],
}
print(json.dumps({"models": [entry]}, indent=2))
PYEOF

echo "[=] 生成された model.json プレビュー:"
head -10 "$CATALOG_TMP" | sed 's/^/    /'

kubectl --context "$KCTX" -n "$NS" create configmap codex-catalog \
  --from-file=model.json="$CATALOG_TMP" \
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
