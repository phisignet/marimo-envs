# Ollama 連携ライブラリ — bootstrap.sh から source して使う。
# common.sh の die / normalize_url 等に依存。
#
# 公開関数:
#   fetch_ollama_model_info <ollama_base_url> <model_name> <output_path>
#                          /api/show の応答 JSON を <output_path> に保存
#   build_codex_model_catalog <show_json_path> <model_name> <output_path>
#                          /api/show の応答から Codex の model.json を組み立て

# fetch_ollama_model_info <ollama_base_url> <model_name> <output_path>:
#   Ollama の /api/show を叩いて応答 JSON を <output_path> に保存。
#   失敗時は curl の stderr と応答内容を表示して die。
#
#   <ollama_base_url> は normalize_url 済(末尾 /v1)を前提。
#   /api/show は /api/ 系(OpenAI互換ではない)なので /v1 を /api に置換する。
fetch_ollama_model_info() {
    local ollama_base_url="$1" model_name="$2" output_path="$3"
    local api_show_url="${ollama_base_url%/v1}/api/show"
    local error_log="${output_path}.err"

    # JSON ペイロードは Python の json.dumps で安全にエスケープして組み立て。
    # model_name に " や \ や改行が含まれていても curl -d が壊れない。
    local payload
    payload=$(CODEX_MODEL="$model_name" python3 -c \
        'import json, os; print(json.dumps({"name": os.environ["CODEX_MODEL"]}))')

    if ! curl -fsS -X POST "$api_show_url" \
            -H 'Content-Type: application/json' \
            -d "$payload" \
            -o "$output_path" 2>"$error_log"; then
        echo "ERROR: Ollama /api/show 呼び出し失敗。${api_show_url} で到達可能で" >&2
        echo "       モデル '${model_name}' が pull 済みであることを確認してください。" >&2
        echo "  curl stderr:" >&2
        sed 's/^/    /' "$error_log" >&2
        if [[ -s "$output_path" ]]; then
            echo "  応答内容(先頭5行):" >&2
            head -5 "$output_path" | sed 's/^/    /' >&2
        fi
        exit 1
    fi
}

# build_codex_model_catalog <show_json_path> <model_name> <output_path>:
#   fetch_ollama_model_info で取得した show 応答 JSON から Codex CLI の
#   model_catalog_json として使える `{"models": [...]}` を組み立て。
#   フィールド構造は Codex 本体の buildCodexModelEntry に揃える。
#
#   出力先 <output_path> に書く(成功時のみ)。失敗時は Python が die する。
#
# 取得項目:
#   - model_info.<family>.context_length(モデルのコンテキスト窓)
#   - capabilities(vision あれば input_modalities に image 追加)
# -cloud サフィックス付きモデルは truncation mode を tokens に。
build_codex_model_catalog() {
    local show_json_path="$1" model_name="$2" output_path="$3"

    # heredoc は <<'PYEOF' でクォートして Python ソースのシェル展開を抑止。
    # 引数(model 名、show 応答 path)は env 経由で渡す(" や \ が含まれても安全)。
    SHOW_JSON_PATH="$show_json_path" \
    CODEX_MODEL="$model_name" \
    python3 <<'PYEOF' > "$output_path"
import json, os
with open(os.environ["SHOW_JSON_PATH"]) as f:
    show = json.load(f)
model_name = os.environ["CODEX_MODEL"]

# context_length は model_info.<family>.context_length に入る(family は様々)
context_window = 128_000  # fallback
for key, value in (show.get("model_info") or {}).items():
    if key.endswith(".context_length") and isinstance(value, int):
        context_window = value
        break

capabilities = show.get("capabilities") or []
input_modalities = ["text"] + (["image"] if "vision" in capabilities else [])

# -cloud モデルは Codex 内部で truncation mode が tokens 扱い
truncation_mode = "tokens" if model_name.endswith("-cloud") else "bytes"

entry = {
    "slug": model_name,
    "display_name": model_name,
    "context_window": context_window,
    "shell_type": "default",
    "visibility": "list",
    "supported_in_api": True,
    "priority": 0,
    "truncation_policy": {"mode": truncation_mode, "limit": 10000},
    "input_modalities": input_modalities,
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
}
