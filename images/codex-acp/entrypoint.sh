#!/bin/sh
# Codex ACPサイドカー起動時に、env から ~/.codex/config.toml を生成し、
# stdio-to-ws codex-acp --port 3021 を起動する。
#
# 環境変数:
#   OLLAMA_BASE_URL  Ollama の OpenAI互換エンドポイント(必須)
#                     例: http://192.168.64.32:11434/v1
#                     末尾は /v1 で、スラッシュなし。
#   CODEX_MODEL      使用モデル名(既定: gemma4:31b-cloud)
#                     例: qwen2.5-coder:32b など。Ollama Cloud モデルなら末尾 -cloud。
#
# 注: wire_api は本構成では明示しない(Ollama 公式の Codex 統合形式に準拠、
# デフォルト = "responses" でそのまま動く)。Codex は 2026 年に "chat" を廃止し
# 現在は "responses" のみサポート(https://github.com/openai/codex/discussions/7782)。
# Ollama も /v1/responses を実装済。
set -e

if [ -z "${OLLAMA_BASE_URL:-}" ]; then
    echo "[entrypoint] ERROR: 環境変数 OLLAMA_BASE_URL が未設定です。" >&2
    echo "[entrypoint]        例: OLLAMA_BASE_URL=http://192.168.64.32:11434/v1" >&2
    exit 1
fi

MODEL="${CODEX_MODEL:-gemma4:31b-cloud}"

mkdir -p "${HOME}/.codex"
# Ollama 公式の Codex 統合ドキュメント(https://docs.ollama.com/integrations/codex)
# が推奨する profile ベースの最小設定を使う:
#   - model_provider 名は "ollama-launch"
#   - profile 経由で model を選ぶ
#   - wire_api / requires_openai_auth は明示せずデフォルトに任せる
#
# context_window:
#   公式注記「Codex requires a larger context window. It is recommended to use a
#   context window of at least 64k tokens.」に従い 65536 をデフォルトに。
#   env CODEX_MODEL_CONTEXT_WINDOW で上書き可。
#
# 注: モデル自称(「OpenAI が開発した」等)を矯正する developer_instructions は
# 意図的に入れない。理由:
#   - 文言にモデル名をハードコードする必要があり、モデル切替時にバグ要因になる
#   - 自称は LLM の幻覚で本質的に解決困難、矯正プロンプトの副作用が大きい
#   - 実通信先と通信内容は別途検証可能(Ollama側ログで証拠取れる)
#
# model_catalog_json: Deployment の codex-catalog ConfigMap volume で
# /etc/codex-catalog/model.json として注入される(readonly)JSON を Codex に読ませる。
# これにより「Model metadata for X not found. Defaulting to fallback metadata」
# 警告が抑制される。内部設計: Ollama PR #15795 が host で
# `ollama launch codex --config` 経由で生成する catalog と同等の JSON を、
# bootstrap.sh が /api/show から動的組み立てして ConfigMap 化する。
# 注入されていない環境では空にして警告抑制機能を無効化(deployment.yaml が
# 必須参照しているので通常は注入される)。
CATALOG_PATH="/etc/codex-catalog/model.json"
[ -r "$CATALOG_PATH" ] || CATALOG_PATH=""

# 注: heredoc 内のコマンド置換 `$( [ -n "$CATALOG_PATH" ] && echo ... )` は
# 空のときに非0終了し、`set -e` 環境(特に dash)で heredoc 全体が異常終了する
# 可能性がある。事前に if/else で文字列変数を作ってから heredoc に埋め込む。
if [ -n "$CATALOG_PATH" ]; then
    CATALOG_LINE="model_catalog_json = \"${CATALOG_PATH}\""
else
    CATALOG_LINE=""
fi

cat > "${HOME}/.codex/config.toml" <<EOF
profile = "ollama-launch"
model_context_window = ${CODEX_MODEL_CONTEXT_WINDOW:-65536}
model_max_output_tokens = ${CODEX_MODEL_MAX_OUTPUT_TOKENS:-8192}
${CATALOG_LINE}

[model_providers.ollama-launch]
name = "Ollama"
base_url = "${OLLAMA_BASE_URL}"

[profiles.ollama-launch]
model = "${MODEL}"
model_provider = "ollama-launch"
EOF

echo "[entrypoint] Codex config:"
sed 's/^/[entrypoint]   /' "${HOME}/.codex/config.toml"

# 本体起動。
# requires_openai_auth=false なので OPENAI_API_KEY は不要だが、codex CLI が
# 起動時に env をチェックする実装の場合があるため、ダミー値を入れておく。
# Ollama リクエストは config.toml 経由なので実際の認証には使われない。
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama-dummy}"

exec stdio-to-ws codex-acp --port 3021
