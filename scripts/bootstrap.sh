#!/usr/bin/env bash
# 統合 bootstrap — Step (1/4) と Agent (claude/codex) の4組合せをサポートする。
#
# 使用例:
#   ./scripts/bootstrap.sh --step 1 --agent codex
#   ./scripts/bootstrap.sh --step 1 --agent claude
#   ./scripts/bootstrap.sh --step 4 --agent codex
#   ./scripts/bootstrap.sh --step 4 --agent claude
#
# Step と Agent の意味:
#   Step 1  1Pod = marimo + ACPサイドカー 1セット(1人試用)
#   Step 4  nginx + 2テナント Pod(複数人 PoC、Hostヘッダ振り分け)
#   claude  ACP = Claude Code(Pro/Max サブスクトークン必須、port 3017)
#   codex   ACP = Codex CLI + Ollama(認証不要、port 3021)
#
# 必要な前提:
#   claude → 環境変数 CLAUDE_CODE_OAUTH_TOKEN(`claude setup-token` で取得)
#   codex  → Ollama が `OLLAMA_HOST=0.0.0.0:11434` で listen、モデル pull 済み
#            (URL は OLLAMA_BASE_URL env で指定、未指定なら hostname -I から自動推測)
set -euo pipefail

# ----- パス/共通変数 -----
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/ollama.sh
source "$REPO_ROOT/scripts/lib/ollama.sh"

CLUSTER_NAME="marimo"
NAMESPACE="marimo"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

# ----- CLI 解析 -----
STEP=""
AGENT=""

usage() {
    cat <<'EOF'
Usage:
  ./scripts/bootstrap.sh --step <1|4> --agent <claude|codex>

Options:
  --step <1|4>           1: 1Pod 試用 / 4: 複数人 nginx 振り分け
  --agent <claude|codex> claude: Claude Code(サブスクトークン)/ codex: Codex CLI + Ollama
  -h, --help             このヘルプを表示

Environment:
  CLAUDE_CODE_OAUTH_TOKEN  --agent claude 時に必須(claude setup-token で取得)
  OLLAMA_BASE_URL          --agent codex 時に推奨(未指定なら hostname -I から自動推測)
  CODEX_MODEL              --agent codex 時のモデル名(既定: gemma4:31b-cloud)
  LAN_IP                   アクセスURL案内で使うLAN IP(未指定なら自動推測)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step)
            [[ $# -ge 2 ]] || { usage >&2; die "--step に値が必要です(1 または 4)。"; }
            STEP="$2"; shift 2 ;;
        --agent)
            [[ $# -ge 2 ]] || { usage >&2; die "--agent に値が必要です(claude または codex)。"; }
            AGENT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
done

if [[ "$STEP" != "1" && "$STEP" != "4" ]]; then
    usage >&2
    die "--step は 1 か 4 で指定してください(現在: '${STEP}')。"
fi
if [[ "$AGENT" != "claude" && "$AGENT" != "codex" ]]; then
    usage >&2
    die "--agent は claude か codex で指定してください(現在: '${AGENT}')。"
fi

echo "[=] bootstrap configuration:"
echo "    STEP  = ${STEP}"
echo "    AGENT = ${AGENT}"

# ----- 前提コマンドチェック -----
require_command docker  "Docker daemon 必須。"
require_command kind    "scripts/install-tools.sh で導入してください。"
require_command kubectl "scripts/install-tools.sh で導入してください。"
# curl / python3 は Codex フローでのみ使う(後の agent別前提チェックで追加要求)

# ----- agent別の前提 env -----
CODEX_MODEL_DEFAULT="gemma4:31b-cloud"

if [[ "$AGENT" == "claude" ]]; then
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        die "環境変数 CLAUDE_CODE_OAUTH_TOKEN が未設定です。

  1) ブラウザのある端末で(Claude Pro/Max ログイン状態で):
       claude setup-token
     出力された1年有効のトークンをコピー。

  2) この端末で:
       export CLAUDE_CODE_OAUTH_TOKEN='<paste-token-here>'
       ./scripts/bootstrap.sh --step ${STEP} --agent claude"
    fi
else
    # codex フロー: curl と python3 は codex-catalog 生成で使う
    require_command curl    "agent=codex の codex-catalog 生成で Ollama /api/show を叩くために必要。"
    require_command python3 "/api/show の JSON から model.json を組み立てるために必要。"

    # codex: OLLAMA_BASE_URL を必須、未指定なら hostname -I から自動推測
    if [[ -z "${OLLAMA_BASE_URL:-}" ]]; then
        auto_ip="$(detect_lan_ip)"
        if [[ -n "$auto_ip" ]]; then
            OLLAMA_BASE_URL="http://${auto_ip}:11434/v1"
            echo "[=] OLLAMA_BASE_URL 未指定 → 自動推測: ${OLLAMA_BASE_URL}"
        else
            die "OLLAMA_BASE_URL 未指定で自動推測も失敗しました。
  Pod から host の Ollama に到達できる URL を明示してください:
    export OLLAMA_BASE_URL='http://192.168.x.x:11434/v1'
    ./scripts/bootstrap.sh --step ${STEP} --agent codex"
        fi
    fi
    OLLAMA_BASE_URL="$(normalize_url "$OLLAMA_BASE_URL")"
    CODEX_MODEL="${CODEX_MODEL:-${CODEX_MODEL_DEFAULT}}"
    echo "[=] Codex設定:"
    echo "    OLLAMA_BASE_URL = ${OLLAMA_BASE_URL}"
    echo "    CODEX_MODEL     = ${CODEX_MODEL}"
fi

# ----- kind クラスタ作成/検証 -----
case "$STEP" in
    1) cluster_config="kind/cluster-step1.yaml"; required_ports=(30718 30317 30321) ;;
    4) cluster_config="kind/cluster-step4.yaml"; required_ports=(30080 30317 30321) ;;
esac

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "[=] kind cluster '${CLUSTER_NAME}' は既に存在します。スキップ。"
    verify_port_mappings "$CLUSTER_NAME" "${required_ports[@]}"
else
    echo "[+] kind cluster '${CLUSTER_NAME}' を作成 (${cluster_config})..."
    kind create cluster --name "$CLUSTER_NAME" --config "$cluster_config"
fi

# ----- agent別 NodePort 競合の事前検知 -----
# Step/agent 切替時に既存 Service が新構成と同じ nodePort を握っていると
# `kubectl apply` が「port is already allocated」で落ちる。kubectl のエラーは
# どの Service が握っているか分かりにくいので、early に check して
# teardown を促す。
#   Step 1: Service marimo が nodePort を直接握る(marimo UI 30718 + agent別 ACP port)
#   Step 4: nginx-gateway が複数 nodePort を集約(http 30080 + agent別 ACP port)
acp_node_port=$([[ "$AGENT" == "claude" ]] && echo 30317 || echo 30321)
case "$STEP" in
    1) allowed_service_name="marimo";        node_ports=(30718 "$acp_node_port") ;;
    4) allowed_service_name="nginx-gateway"; node_ports=(30080 "$acp_node_port") ;;
esac
for node_port in "${node_ports[@]}"; do
    check_nodeport_conflict "$KUBE_CONTEXT" "$NAMESPACE" "$node_port" "$allowed_service_name"
done

# ----- カスタムイメージ build & kind load -----
# image タグは「マニフェストを唯一の真の情報源」とし、bootstrap が build/load する
# タグと kubectl apply で動かす Deployment のタグが drift しないようマニフェストから
# 抽出する(過去 PR で確立した方針)。
#
# 検索範囲は manifests/step${STEP} 全体。step1 では marimo image が base/ にあるので
# overlay (codex|claude) だけ見ると拾えない、と base のみ見ると agent差分が拾えない。
# 全体検索なら両方拾える(片方の agent overlay の image も拾うが、agent ごとに
# image prefix を分けているので競合しない: codex-acp と acp-agent は別 prefix)。
manifest_search_root="manifests/step${STEP}"
case "$AGENT" in
    claude) acp_image_prefix="marimo-envs/acp-agent:"; acp_dir="images/acp-agent" ;;
    codex)  acp_image_prefix="marimo-envs/codex-acp:"; acp_dir="images/codex-acp" ;;
esac
marimo_image="$(extract_image "$manifest_search_root" "marimo-envs/marimo:")"
acp_image="$(extract_image    "$manifest_search_root" "$acp_image_prefix")"
[[ -n "$marimo_image" ]] || die "${manifest_search_root} から marimo image を抽出できませんでした。"
[[ -n "$acp_image"    ]] || die "${manifest_search_root} から ${AGENT} image を抽出できませんでした。"
echo "[=] images from ${manifest_search_root}:"
echo "    marimo_image = ${marimo_image}"
echo "    acp_image    = ${acp_image}"

echo "[+] marimo拡張イメージをビルド: ${marimo_image}"
docker build -t "$marimo_image" images/marimo

echo "[+] ${AGENT} ACPサイドカーイメージをビルド: ${acp_image}"
docker build -t "$acp_image" "$acp_dir"

echo "[+] 両イメージを kind クラスタに load..."
kind load docker-image "$marimo_image" --name "$CLUSTER_NAME"
kind load docker-image "$acp_image"    --name "$CLUSTER_NAME"

# ----- Namespace -----
echo "[+] Namespace を適用..."
kubectl --context "$KUBE_CONTEXT" apply -f manifests/namespace.yaml

# ----- agent別の動的リソース(Secret / ConfigMap)作成 -----
if [[ "$AGENT" == "claude" ]]; then
    echo "[+] Claude OAuth トークン Secret を作成/更新..."
    # --from-literal=token=$TOKEN だとプロセス引数として残り、同一ホストの他ユーザーが
    # `ps` でトークンを読めてしまう。一時ファイル(mode 600)+ --from-file 経由で
    # コマンドラインにトークンを載せないようにする。
    token_file="$(mktemp)"
    chmod 600 "$token_file"
    # EXIT trap を一時的に上書きして、途中で失敗した場合も $token_file を確実に
    # 削除する。Bash の trap はシグナルごとに1つのハンドラしか持てないので、
    # この区間は EXIT trap が rm 専用に置き換わる。区間終了時に `trap - EXIT` で
    # デフォルト(なし)に戻す。Codex 側の trap(catalog_dir 削除)は別のフロー
    # なのでこの区間とは重ならない。
    trap 'rm -f "$token_file"' EXIT
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > "$token_file"
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic claude-code-token \
        --from-file=token="$token_file" \
        --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
    rm -f "$token_file"
    trap - EXIT
else
    echo "[+] Codex 接続 ConfigMap (codex-config) を作成/更新..."
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create configmap codex-config \
        --from-literal=ollama_base_url="$OLLAMA_BASE_URL" \
        --from-literal=model="$CODEX_MODEL" \
        --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

    echo "[+] codex-catalog を Ollama /api/show から動的生成..."
    catalog_dir="$(mktemp -d)"
    trap 'rm -rf "$catalog_dir"' EXIT

    fetch_ollama_model_info "$OLLAMA_BASE_URL" "$CODEX_MODEL" "$catalog_dir/api-show.json"
    build_codex_model_catalog "$catalog_dir/api-show.json" "$CODEX_MODEL" "$catalog_dir/model.json"

    echo "[=] 生成された model.json プレビュー:"
    head -10 "$catalog_dir/model.json" | sed 's/^/    /'

    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create configmap codex-catalog \
        --from-file=model.json="$catalog_dir/model.json" \
        --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
fi

# ----- マニフェスト適用 -----
overlay="manifests/step${STEP}/${AGENT}"
echo "[+] manifest を適用: ${overlay}"
kubectl --context "$KUBE_CONTEXT" apply -k "$overlay"

# ----- rollout 再起動&待機 -----
case "$STEP" in
    1)
        deployments=(marimo)
        rollout_timeouts=(300)
        ;;
    4)
        deployments=(nginx-gateway marimo-nb1 marimo-nb2)
        rollout_timeouts=(120 300 300)
        ;;
esac

echo "[+] 全 Deployment を rollout restart (新 Secret/ConfigMap を確実に読ませる)..."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" rollout restart \
    "${deployments[@]/#/deploy/}"

echo "[+] rollout 完了を待機..."
for i in "${!deployments[@]}"; do
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" rollout status \
        "deploy/${deployments[$i]}" --timeout="${rollout_timeouts[$i]}s"
done

# ----- アクセス情報 -----
lan_ip="${LAN_IP:-$(detect_lan_ip)}"

echo
echo "===================================================================="
echo " marimo + ${AGENT} ACP は起動しました (Step ${STEP})."
echo
case "$STEP" in
    1)
        agent_port=$([[ "$AGENT" == "claude" ]] && echo 3017 || echo 3021)
        echo " このマシンから:"
        echo "   http://localhost:2718/"
        if [[ -n "$lan_ip" ]]; then
            echo
            echo " 同じLAN上の他PCから:"
            echo "   http://${lan_ip}:2718/"
        fi
        echo
        echo " marimo UI で:"
        echo "   1. Settings → Lab → \"agents\" を有効化(初回のみ)"
        echo "   2. 左サイドバーのエージェントアイコン"
        echo "   3. ドロップダウンから \"${AGENT^}\" を選択"
        echo "   4. ブラウザは ws://<同じホスト>:${agent_port}/message に自動接続"
        ;;
    4)
        if [[ -n "$lan_ip" ]]; then
            echo " アクセスURL(同じLAN上のどの端末からでも):"
            echo "   nb1: http://nb1.${lan_ip}.nip.io/"
            echo "   nb2: http://nb2.${lan_ip}.nip.io/"
        else
            echo " LAN IP の自動推測に失敗。nip.io 用に LAN_IP env を明示指定してください。"
        fi
        ;;
esac

echo
echo " 状態確認:"
echo "   kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get pods,svc"
for dep in "${deployments[@]}"; do
    echo "   kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} logs deploy/${dep}"
done
echo
echo " 後片付け:"
echo "   ./scripts/teardown.sh"
echo "===================================================================="
