#!/usr/bin/env bats
# bootstrap.sh の引数バリデーションのテスト。
# require_command(docker/kind/kubectl)より手前で弾かれる検証のみ対象なので、
# Docker/kind が無い環境でも決定的に走る(副作用なし)。

load test_helper

setup() {
    BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
}

@test "--help は exit 0 で Usage を表示" {
    run bash "$BOOTSTRAP" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "不正な --step はエラー終了" {
    run bash "$BOOTSTRAP" --step 9 --agent claude
    [ "$status" -ne 0 ]
    [[ "$output" == *"--step"* ]]
}

@test "不正な --agent はエラー終了" {
    run bash "$BOOTSTRAP" --step 1 --agent bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"--agent"* ]]
}

@test "不明な引数はエラー終了" {
    run bash "$BOOTSTRAP" --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "--step に値が無いとエラー終了" {
    run bash "$BOOTSTRAP" --step
    [ "$status" -ne 0 ]
}

@test "--agent に値が無いとエラー終了" {
    run bash "$BOOTSTRAP" --step 1 --agent
    [ "$status" -ne 0 ]
}
