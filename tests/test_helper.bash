# shellcheck shell=bash
# bats 共通ヘルパ。各 .bats から `load test_helper` で読み込む。
# REPO_ROOT を解決して export する(各テストが lib/* や manifests/* を参照するため)。

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export TESTS_DIR REPO_ROOT
