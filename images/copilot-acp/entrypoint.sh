#!/bin/sh
# Copilot ACP サイドカー起動時に COPILOT_GITHUB_TOKEN を確認し、
# stdio-to-ws + `copilot --acp --stdio` を port 3025 で起動する。
#
# 環境変数:
#   COPILOT_GITHUB_TOKEN   必須。Copilot 利用権限を持つ GitHub PAT。
#                           Secret copilot-token(キー: token)経由で注入される。
#   COPILOT_DISABLE_YOLO   "1" で yolo (--allow-all) を無効化する escape hatch。
#                           既定は無効=yolo ON(=全ツール承認スキップ)。
#                           ⚠️ yolo はシェル実行・任意のファイル書き込みも含めて
#                              無承認で実行する。共有環境で他人と同じ PVC を触る
#                              場合は "1" にして承認制(Agent モード)に戻すこと。
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

# yolo (--allow-all) — 既定 ON、COPILOT_DISABLE_YOLO=1 で OFF
YOLO_FLAG="--allow-all"
yolo_mode="on"
if [ "${COPILOT_DISABLE_YOLO:-0}" = "1" ]; then
    YOLO_FLAG=""
    yolo_mode="off (承認モード)"
fi

echo "[entrypoint] Starting Copilot ACP server on port 3025... (yolo: ${yolo_mode})"
# シェル展開: $YOLO_FLAG が空なら追加引数なし、 --allow-all なら付与
exec stdio-to-ws "copilot --acp ${YOLO_FLAG} --stdio" --port 3025
