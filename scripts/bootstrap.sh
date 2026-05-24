#!/usr/bin/env bash
# Step 1(1人での試用)用のワンショットbootstrap。
# - kindクラスタを起動(なければ)
# - ACPサイドカーイメージをビルドしてkindにload
# - Claude OAuth トークンを Secret 化
# - マニフェスト一式を適用
# - 起動を待ってアクセスURLを表示
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLUSTER_NAME="marimo"
NS="marimo"
# 以降の kubectl 呼び出しはすべてこの context を明示する。
# ユーザーの current context が別クラスタを指していても、誤って apply されることを防ぐ。
KCTX="kind-${CLUSTER_NAME}"

# Image タグは manifests/step1/ を single source of truth として扱う。
# bootstrap.sh が build/load するタグと、kubectl apply で動かす Deployment の
# タグが drift する事故(片方だけ更新したケース)を構造的に排除する。
extract_image() {
  # 例: "image: marimo-envs/marimo:0.1.0  # comment" → "marimo-envs/marimo:0.1.0"
  #
  # 注: set -euo pipefail 下では grep 未マッチ (exit 1) で関数自体が即終了し、
  # 下の [[ -z ... ]] の親切なエラーメッセージに辿り着けない。
  # { ...; } || true で握りつぶし、空文字を返して後段チェックに委ねる。
  { grep -REh "^[[:space:]]+image:[[:space:]]+$1" manifests/step1/ \
      | head -1 | awk '{print $2}'; } || true
}
MARIMO_IMAGE="$(extract_image 'marimo-envs/marimo:')"
ACP_IMAGE="$(extract_image   'marimo-envs/acp-agent:')"

if [[ -z "$MARIMO_IMAGE" || -z "$ACP_IMAGE" ]]; then
  echo "ERROR: manifests/step1/ から marimo / acp-agent の image タグを抽出できませんでした。" >&2
  echo "  実装側で image 行のフォーマットが変わっていないか確認してください。" >&2
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

if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: 環境変数 CLAUDE_CODE_OAUTH_TOKEN が未設定です。

  1) ブラウザのある手元の端末で(Claude Pro/Max にログインした状態で):
       claude setup-token
     表示された1年有効のOAuthトークンをコピーします。

  2) この端末で以下のように設定してから再実行してください:
       export CLAUDE_CODE_OAUTH_TOKEN='<paste-token-here>'
       ./scripts/bootstrap.sh
EOF
  exit 1
fi

# -------- kindクラスタ --------
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[=] kind cluster '${CLUSTER_NAME}' は既に存在します。スキップ。"
else
  echo "[+] kind cluster '${CLUSTER_NAME}' を作成..."
  kind create cluster --name "$CLUSTER_NAME" --config kind/cluster.yaml
fi

# Step 1 と Step 4 は同じ NodePort 30317 を使うため、既に Step 4 (nginx-gateway)
# が apply 済みの状態で Step 1 を実行すると Service 作成が NodePort 競合で失敗する。
# 早期検知して teardown を促す。bootstrap-step4.sh の対称ガード。
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  conflicting=$({ kubectl --context "$KCTX" -n "$NS" get svc \
    -o go-template='{{range .items}}{{$name := .metadata.name}}{{range .spec.ports}}{{if eq .nodePort 30317}}{{$name}}{{"\n"}}{{end}}{{end}}{{end}}' \
    2>/dev/null | grep -v '^marimo$' | grep -v '^$' | head -1; } || true)
  if [[ -n "$conflicting" ]]; then
    cat >&2 <<EOF
ERROR: NodePort 30317 が既に Service '${conflicting}' に割り当てられています。
   Step 4 (manifests/step4/nginx-deployment.yaml) が同じ NodePort を使うため、
   Step 4 が適用済みの状態で Step 1 を実行すると競合します。先に teardown してください:

       ./scripts/teardown.sh   # kindクラスタごと削除、その後再実行

   または Step 4 の nginx-gateway Service だけ手動で消す:
       kubectl --context ${KCTX} -n ${NS} delete \\
           deploy/nginx-gateway svc/nginx-gateway \\
           deploy/marimo-nb1    svc/marimo-nb1 \\
           deploy/marimo-nb2    svc/marimo-nb2
EOF
    exit 1
  fi
fi

# -------- カスタムイメージ群 --------
echo "[+] marimo拡張イメージ(marimo[mcp]入り)をビルド: ${MARIMO_IMAGE}"
docker build -t "$MARIMO_IMAGE" images/marimo

echo "[+] ACPサイドカーイメージをビルド: ${ACP_IMAGE}"
docker build -t "$ACP_IMAGE" images/acp-agent

echo "[+] 両イメージをkindクラスタにload..."
kind load docker-image "$MARIMO_IMAGE" --name "$CLUSTER_NAME"
kind load docker-image "$ACP_IMAGE"    --name "$CLUSTER_NAME"

# -------- マニフェスト適用 --------
echo "[+] Namespace と PVC を適用..."
kubectl --context "$KCTX" apply -f manifests/namespace.yaml
kubectl --context "$KCTX" apply -f manifests/step1/pvc.yaml

echo "[+] Claude OAuth トークン Secret を作成/更新..."
kubectl --context "$KCTX" -n "$NS" create secret generic claude-code-token \
  --from-literal=token="$CLAUDE_CODE_OAUTH_TOKEN" \
  --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f -

echo "[+] Deployment と Service を適用..."
kubectl --context "$KCTX" apply -f manifests/step1/deployment.yaml
kubectl --context "$KCTX" apply -f manifests/step1/service.yaml

# Secret だけ更新して Deployment マニフェスト自体は変わらないケース(=トークン更新の再実行)
# でも、走っているPodが自動で新Secretを読み直すことはないため、明示的にrollout restartして
# 強制的に新Podを起動する。初回作成時も実害なし(annotationが1つ増えるだけ)。
echo "[+] Pod を新Secretで再生成(rollout restart)..."
kubectl --context "$KCTX" -n "$NS" rollout restart deployment/marimo

# -------- 起動待ち --------
echo "[+] marimo Deployment の rollout を待機..."
kubectl --context "$KCTX" -n "$NS" rollout status deployment/marimo --timeout=300s

# -------- アクセス情報 --------
# IPv6 や docker bridge (172.17.x.x) を避けて IPv4 のLAN IPを優先選択。
# 環境変数 LAN_IP が指定されていればそれを優先。
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
 marimo + Claude Code ACP は起動しました。

 このマシンから:
   http://localhost:2718/

EOF
if [[ -n "${LAN_IP}" ]]; then
  cat <<EOF
 同じLAN上の他PCから:
   http://${LAN_IP}:2718/

EOF
fi
cat <<'EOF'
 marimo UI を開いたら:
   1. Settings (右上歯車) → Lab → "agents" を有効化
   2. 左サイドバーのエージェントアイコンをクリック
   3. ドロップダウンから "Claude" を選択
   4. ブラウザは ws://<同じホスト>:3017/message に自動接続します

 状態確認(current context が別クラスタの可能性に備えて --context を明示):
   kubectl --context kind-marimo -n marimo get pods,svc
   kubectl --context kind-marimo -n marimo logs deploy/marimo -c marimo
   kubectl --context kind-marimo -n marimo logs deploy/marimo -c acp-agent

 (常に kind-marimo を使うなら一度だけ default に固定する手もある:
   kubectl config use-context kind-marimo)

 後片付け:
   ./scripts/teardown.sh
====================================================================
EOF
