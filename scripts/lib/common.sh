# 共通ライブラリ — bootstrap.sh / teardown.sh から source して使う。
# このファイル単体での実行は想定しない(set -e は呼び出し側の責任)。
#
# 公開関数:
#   die <message>           STDERR にメッセージを出して exit 1
#   require_command <cmd> <description>  コマンド存在チェック、無ければ die
#   detect_lan_ip           hostname -I から LAN の IPv4 を抽出(2段fallback)
#   normalize_url <url>     末尾スラッシュ除去 + /v1 サフィックス保証
#   require_kind_cluster <name>   kind クラスタの存在チェック、無ければ die
#   verify_port_mappings <cluster> <port...>  kind ノードに指定ポートが bind されているか
#   check_nodeport_conflict <context> <allowed_namespace> <node_port> <allowed_service_name>
#                           NodePort 衝突を事前検知(全 namespace 走査、
#                           allowed_namespace/allowed_service_name と完全一致するものは除外)
#   extract_image <manifest_search_root> <image_name_prefix>
#                           マニフェスト配下を再帰検索して `image:` 行を抽出
#                           (image タグの単一情報源化)
#   create_token_secret <context> <namespace> <secret_name> <token_value>
#                           1つのトークンを持つSecretを冪等apply。トークン値が
#                           `ps` 等から見えないよう一時ファイル(mode 600)+
#                           --from-file 経由で渡す。

# ----- 基本ユーティリティ -----

# die <message>: エラーメッセージを STDERR に出して exit 1
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# require_command <cmd> <description>:
#   コマンドが PATH に無ければ description 付きで die。
require_command() {
    local command="$1" description="$2"
    if ! command -v "$command" >/dev/null 2>&1; then
        die "$command が見つかりません。$description"
    fi
}

# ----- LAN IP 検出 -----

# detect_lan_ip:
#   hostname -I から LAN の IPv4 アドレスを 1 つ抽出して echo する。
#   1段目: 192.168.x.x / 10.x.x.x など「家庭/社内LANらしい」を優先
#          (docker bridge 172.16-31.x.x と loopback 127.x.x.x は除外)。
#   2段目: 1段目が空のとき loopback だけ除外して再試行。
#          見つかったら警告を STDERR に出力(docker bridge 誤選択の可能性ありのため)。
#   どちらでも見つからなければ空文字を返す。
#
# 呼び出し側:
#   lan_ip="$(detect_lan_ip)" や if lan_ip="$(detect_lan_ip)" && [[ -n "$lan_ip" ]]; then ... fi
detect_lan_ip() {
    local lan_ip
    lan_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
        | grep -v -E '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
        | head -1)"
    if [[ -z "$lan_ip" ]]; then
        lan_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
            | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
            | grep -v -E '^127\.' \
            | head -1)"
        if [[ -n "$lan_ip" ]]; then
            echo "  WARN: 192.168.x.x / 10.x.x.x が見つからず、172.x.x.x の lan_ip=${lan_ip}" >&2
            echo "        を選択。docker/kind の bridge ネットワークの可能性があります。" >&2
        fi
    fi
    echo "$lan_ip"
}

# ----- URL 正規化 -----

# normalize_url <url>:
#   末尾スラッシュを除去し、/v1 で終わるよう保証して echo する。
#   入力例:
#     http://x.x.x.x:11434         → http://x.x.x.x:11434/v1
#     http://x.x.x.x:11434/         → http://x.x.x.x:11434/v1
#     http://x.x.x.x:11434/v1       → http://x.x.x.x:11434/v1
#     http://x.x.x.x:11434/v1/      → http://x.x.x.x:11434/v1
normalize_url() {
    local url="${1%/}"
    case "$url" in
        */v1) ;;
        *) url="${url}/v1" ;;
    esac
    echo "$url"
}

# ----- kind クラスタ検証 -----

# require_kind_cluster <name>:
#   指定名の kind クラスタが存在しなければ die。
require_kind_cluster() {
    local name="$1"
    if ! kind get clusters 2>/dev/null | grep -q "^${name}$"; then
        die "kind クラスタ '${name}' が存在しません。bootstrap.sh で作成してください。"
    fi
}

# verify_port_mappings <cluster_name> <port...>:
#   kind ノードコンテナに指定の containerPort が docker port で確認できるか検証。
#   欠落があれば die(teardown 案内付き)。
#   呼び出し例: verify_port_mappings marimo 30718 30317
verify_port_mappings() {
    local cluster_name="$1"; shift
    local node_container="${cluster_name}-control-plane"
    local missing=()
    local port
    for port in "$@"; do
        if ! docker port "$node_container" "${port}/tcp" >/dev/null 2>&1; then
            missing+=("$port")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "既存の kind クラスタ '${cluster_name}' に必要なポートマッピングが
       ありません(欠落: ${missing[*]})。
       他の Step 用 cluster 設定で作られた可能性があります。teardown して再作成してください:

           ./scripts/teardown.sh
           ./scripts/bootstrap.sh --step <STEP> --agent <AGENT>"
    fi
}

# check_nodeport_conflict <context> <allowed_namespace> <node_port> <allowed_service_name>:
#   指定 NodePort を「<allowed_namespace>/<allowed_service_name> と完全一致する
#   Service 以外」が握っていないか検証。衝突していれば die(teardown 案内付き)。
#
#   NodePort はクラスタ全体で一意なため `kubectl get svc -A` で全 namespace を
#   走査する。自分自身を除外するには namespace + name の組を完全一致で照合。
#
#   引数:
#     context              kubectl --context に渡す値(例: kind-marimo)
#     allowed_namespace    自分自身の Service が居る namespace(例: marimo)
#     node_port            検査対象 NodePort(例: 30317)
#     allowed_service_name 自分自身の Service 名(例: marimo)
#                          allowed_namespace/allowed_service_name の組と完全一致する
#                          ものを除外(glob/正規表現ではない)
check_nodeport_conflict() {
    local context="$1" allowed_namespace="$2" node_port="$3" allowed_service_name="$4"
    local conflicting
    conflicting=$({ kubectl --context "$context" get svc -A \
        -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$name := .metadata.name}}{{range .spec.ports}}{{if eq .nodePort '"${node_port}"'}}{{$ns}}/{{$name}}{{"\n"}}{{end}}{{end}}{{end}}' \
        2>/dev/null | grep -v "^${allowed_namespace}/${allowed_service_name}\$" | grep -v '^$' | head -1; } || true)
    if [[ -n "$conflicting" ]]; then
        # ${conflicting} は '<namespace>/<name>' 形式。kubectl delete に渡せるよう
        # ヒント文で分解例を示す。
        local conflicting_ns="${conflicting%%/*}"
        local conflicting_name="${conflicting##*/}"
        die "NodePort ${node_port} が既に Service '${conflicting}' に割り当てられています。
       競合 Service を削除するか、Step/agent 切替の場合はクラスタを teardown してください:

           kubectl --context ${context} -n ${conflicting_ns} delete svc ${conflicting_name}
                                                                  # 競合 Service のみ削除
           ./scripts/teardown.sh                                   # クラスタごと削除"
    fi
}

# extract_image <manifest_search_root> <image_name_prefix>:
#   マニフェストツリーから `image: <prefix>...` を含む行を再帰検索し、最初に見つかった
#   image 値を echo する。bootstrap.sh が docker build / kind load する image タグと、
#   kubectl apply で動かす Deployment の image タグを「マニフェストを唯一の真の情報源」
#   とすることで drift を構造的に排除する。
#
#   引数:
#     manifest_search_root  検索開始ディレクトリ(例: manifests/step1)
#     image_name_prefix     image 名のプレフィックス(例: "marimo-envs/codex-acp:")
#
#   注意: set -euo pipefail 下では grep 未マッチで関数が即終了する。
#   { ...; } || true で握りつぶし、空文字を返して呼び出し側のチェックに委ねる。
extract_image() {
    local manifest_search_root="$1" image_name_prefix="$2"
    { grep -REh "^[[:space:]]+image:[[:space:]]+${image_name_prefix}" "$manifest_search_root" \
        | head -1 | awk '{print $2}'; } || true
}

# create_token_secret <context> <namespace> <secret_name> <token_value>:
#   トークン1個を持つ Secret(キー名は固定で "token")を冪等に apply する。
#
#   `kubectl create secret --from-literal=token=$VALUE` だと、トークン値が
#   プロセス引数として残り `ps` 等で同一ホストの他ユーザーから見えてしまう。
#   一時ファイル(mode 600)に書き出して `--from-file=token=<file>` 経由で
#   渡すことで、コマンドラインへの値露出を回避。EXIT trap で一時ファイルを
#   確実に削除する(関数終了後に trap を元に戻す)。
#
#   呼び出し例:
#     create_token_secret "$KUBE_CONTEXT" "$NAMESPACE" \
#         claude-code-token "$CLAUDE_CODE_OAUTH_TOKEN"
#     create_token_secret "$KUBE_CONTEXT" "$NAMESPACE" \
#         copilot-token     "$COPILOT_GITHUB_TOKEN"
create_token_secret() {
    local context="$1" namespace="$2" secret_name="$3" token_value="$4"
    local token_file
    token_file="$(mktemp)"
    chmod 600 "$token_file"
    trap 'rm -f "$token_file"' EXIT
    printf '%s' "$token_value" > "$token_file"
    kubectl --context "$context" -n "$namespace" create secret generic "$secret_name" \
        --from-file=token="$token_file" \
        --dry-run=client -o yaml | kubectl --context "$context" apply -f -
    rm -f "$token_file"
    trap - EXIT
}
