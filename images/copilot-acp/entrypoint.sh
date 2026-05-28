#!/bin/sh
# Copilot ACP サイドカー起動時に COPILOT_GITHUB_TOKEN を確認し、
# stdio-to-ws + `copilot --acp --stdio` を port 3025 で起動する。
#
# 環境変数:
#   COPILOT_GITHUB_TOKEN  必須。Copilot 利用権限を持つ GitHub PAT。
#                          Secret copilot-token(キー: token)経由で注入される。
#
# Copilot CLI のクレデンシャル優先順位(公式ドキュメントより):
#   COPILOT_GITHUB_TOKEN > GH_TOKEN > GITHUB_TOKEN > keychain > gh auth token
#
# Pod 内で GH_TOKEN / GITHUB_TOKEN を念のため unset する理由:
#   ローカル検証時に「無効値の GH_TOKEN が env に残り、OAuth login を上書きして
#   401 ループ」する罠を踏んだため。Pod 内は Copilot 専用環境なので、
#   COPILOT_GITHUB_TOKEN のみが見える状態を強制する。
set -e

if [ -z "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "[entrypoint] ERROR: 環境変数 COPILOT_GITHUB_TOKEN が未設定です。" >&2
    echo "[entrypoint]        GitHub PAT(Copilot 利用権限あり)を Secret 経由で渡してください。" >&2
    exit 1
fi

unset GH_TOKEN GITHUB_TOKEN

echo "[entrypoint] Starting Copilot ACP server on port 3025..."
exec stdio-to-ws "copilot --acp --stdio" --port 3025
