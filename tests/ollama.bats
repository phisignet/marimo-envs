#!/usr/bin/env bats
# scripts/lib/ollama.sh の build_codex_model_catalog のユニットテスト。
# fetch_ollama_model_info は curl(ネットワーク)依存のため対象外。

load test_helper

setup() {
    command -v python3 >/dev/null || skip "python3 が無い"
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/ollama.sh"
}

@test "build_codex_model_catalog: context_length / vision / -cloud を反映" {
    local out="$BATS_TEST_TMPDIR/catalog.json"
    run build_codex_model_catalog "$REPO_ROOT/tests/fixtures/ollama-show.json" "gemma4:31b-cloud" "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    # context_window は model_info.<family>.context_length(65536)を反映
    run python3 -c "import json;d=json.load(open('$out'));m=d['models'][0];print(m['context_window'])"
    [ "$output" = "65536" ]
    # vision capability → input_modalities に image
    run python3 -c "import json;d=json.load(open('$out'));print('image' in d['models'][0]['input_modalities'])"
    [ "$output" = "True" ]
    # -cloud → truncation mode tokens
    run python3 -c "import json;d=json.load(open('$out'));print(d['models'][0]['truncation_policy']['mode'])"
    [ "$output" = "tokens" ]
    # slug は model 名
    run python3 -c "import json;d=json.load(open('$out'));print(d['models'][0]['slug'])"
    [ "$output" = "gemma4:31b-cloud" ]
}

@test "build_codex_model_catalog: 非 vision / 非 cloud は image なし・bytes" {
    local show="$BATS_TEST_TMPDIR/show.json"
    cat > "$show" <<'JSON'
{"model_info": {"qwen.context_length": 32768}, "capabilities": ["completion"]}
JSON
    local out="$BATS_TEST_TMPDIR/catalog2.json"
    run build_codex_model_catalog "$show" "qwen2.5-coder:32b" "$out"
    [ "$status" -eq 0 ]
    run python3 -c "import json;d=json.load(open('$out'));m=d['models'][0];print(m['context_window'], 'image' in m['input_modalities'], m['truncation_policy']['mode'])"
    [ "$output" = "32768 False bytes" ]
}

@test "build_codex_model_catalog: context_length 欠落時は fallback 128000" {
    local show="$BATS_TEST_TMPDIR/show3.json"
    echo '{"capabilities": []}' > "$show"
    local out="$BATS_TEST_TMPDIR/catalog3.json"
    run build_codex_model_catalog "$show" "some-model" "$out"
    [ "$status" -eq 0 ]
    run python3 -c "import json;print(json.load(open('$out'))['models'][0]['context_window'])"
    [ "$output" = "128000" ]
}
