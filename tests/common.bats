#!/usr/bin/env bats
# scripts/lib/common.sh の純粋ロジック関数のユニットテスト。
# kubectl/kind/docker に依存する関数(require_kind_cluster 等)は環境依存のため対象外。

load test_helper

setup() {
    source "$REPO_ROOT/scripts/lib/common.sh"
}

# ----- normalize_url -----

@test "normalize_url: スキーム+host のみ → /v1 を付与" {
    run normalize_url "http://192.168.0.1:11434"
    [ "$status" -eq 0 ]
    [ "$output" = "http://192.168.0.1:11434/v1" ]
}

@test "normalize_url: 末尾スラッシュを除去して /v1 付与" {
    run normalize_url "http://x:11434/"
    [ "$output" = "http://x:11434/v1" ]
}

@test "normalize_url: 既に /v1 ならそのまま" {
    run normalize_url "http://x:11434/v1"
    [ "$output" = "http://x:11434/v1" ]
}

@test "normalize_url: /v1/ の末尾スラッシュのみ除去" {
    run normalize_url "http://x:11434/v1/"
    [ "$output" = "http://x:11434/v1" ]
}

# ----- die -----

@test "die: ERROR を stderr に出して exit 1" {
    run die "なにか失敗"
    [ "$status" -eq 1 ]
    [[ "$output" == "ERROR: なにか失敗" ]]
}

# ----- require_command -----

@test "require_command: 存在するコマンドは成功(出力なし)" {
    run require_command bash "bash は必須"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "require_command: 存在しないコマンドは die(説明文を含む)" {
    run require_command __definitely_not_a_real_command__ "導入してください"
    [ "$status" -eq 1 ]
    [[ "$output" == *"見つかりません"* ]]
    [[ "$output" == *"導入してください"* ]]
}

# ----- detect_lan_ip(hostname をスタブ) -----

@test "detect_lan_ip: 192.168 を優先し docker bridge(172.17)を除外" {
    hostname() { echo "172.17.0.1 192.168.10.5"; }
    run detect_lan_ip
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.10.5" ]
}

@test "detect_lan_ip: loopback のみなら空を返す" {
    hostname() { echo "127.0.0.1"; }
    run detect_lan_ip
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "detect_lan_ip: 172.17 しか無ければ警告付きでフォールバック選択" {
    hostname() { echo "172.17.0.1"; }
    run detect_lan_ip
    [ "$status" -eq 0 ]
    # 出力(stdout+stderr)に IP と WARN が含まれる
    [[ "$output" == *"172.17.0.1"* ]]
    [[ "$output" == *"WARN"* ]]
}

# ----- extract_image -----

@test "extract_image: manifest から image 名を抽出" {
    local dir="$BATS_TEST_TMPDIR/manifests"
    mkdir -p "$dir"
    cat > "$dir/deploy.yaml" <<'YAML'
spec:
  containers:
    - name: marimo
      image: marimo-envs/marimo:0.1.0
YAML
    run extract_image "$dir" "marimo-envs/marimo:"
    [ "$status" -eq 0 ]
    [ "$output" = "marimo-envs/marimo:0.1.0" ]
}

@test "extract_image: 該当なしなら空(set -e でも落ちない)" {
    local dir="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$dir"
    echo "no image here" > "$dir/x.yaml"
    run extract_image "$dir" "marimo-envs/marimo:"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
