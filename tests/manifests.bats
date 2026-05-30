#!/usr/bin/env bats
# kustomize overlay が render できることの検証(成果物テスト)。
# kubectl(kustomize 内蔵)で全 6 overlay(step1/step4 × claude/codex/copilot)を build する。

load test_helper

setup() {
    command -v kubectl >/dev/null || skip "kubectl が無い"
}

# 各 overlay が空でない YAML を出力し、exit 0 になることを確認する。
kustomize_ok() {
    local dir="$1"
    run kubectl kustomize "$REPO_ROOT/$dir"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"kind:"* ]]
}

@test "step1/claude が build できる"  { kustomize_ok manifests/step1/claude; }
@test "step1/codex が build できる"   { kustomize_ok manifests/step1/codex; }
@test "step1/copilot が build できる" { kustomize_ok manifests/step1/copilot; }
@test "step4/claude が build できる"  { kustomize_ok manifests/step4/claude; }
@test "step4/codex が build できる"   { kustomize_ok manifests/step4/codex; }
@test "step4/copilot が build できる" { kustomize_ok manifests/step4/copilot; }
