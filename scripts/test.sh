#!/usr/bin/env bash
# プロジェクトのテストランナー。shellcheck(静的解析)と bats(ユニット/成果物)を
# まとめて実行する。ツールが無ければ該当ステップをスキップ(CI 不使用前提のため
# ローカルで気軽に回せるようにする)。
#
# 使い方:
#   ./scripts/test.sh
#
# ツール導入(sudo 不要、~/.local/bin):
#   ./scripts/install-test-tools.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# このランナーは set -e を使わない(shellcheck/bats を両方最後まで走らせ fail を集約
# するため)。そのため cd 失敗は明示的にガードする(SC2164)。
cd "$REPO_ROOT" || { echo "ERROR: REPO_ROOT へ cd できません: ${REPO_ROOT}" >&2; exit 1; }

fail=0

echo "== shellcheck (静的解析) =="
if command -v shellcheck >/dev/null 2>&1; then
    # プロジェクト自前のシェルスクリプトのみ対象(vendored marimo-pair skill は除外)。
    mapfile -t sh_files < <(git ls-files 'scripts/*.sh' 'images/*/entrypoint.sh')
    if shellcheck "${sh_files[@]}"; then
        echo "  shellcheck: OK (${#sh_files[@]} files)"
    else
        echo "  shellcheck: 失敗" >&2
        fail=1
    fi
else
    echo "  shellcheck 未インストール → スキップ(install-test-tools.sh で導入可)"
fi

echo "== bats (ユニット / 成果物テスト) =="
if command -v bats >/dev/null 2>&1; then
    if bats "$REPO_ROOT/tests/"; then
        echo "  bats: OK"
    else
        echo "  bats: 失敗" >&2
        fail=1
    fi
else
    echo "  bats 未インストール → スキップ(install-test-tools.sh で導入可)"
fi

if [[ "$fail" -eq 0 ]]; then
    echo "== すべて成功 =="
else
    echo "== 失敗あり ==" >&2
fi
exit "$fail"
