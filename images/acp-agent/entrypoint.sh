#!/bin/sh
# ACPサイドカー起動時に、同Pod内 marimo の MCP サーバーを Claude Code 設定へ
# 登録してから stdio-to-ws (= claude-code-acp) を立ち上げる。
#
# 登録するMCPサーバー:
#   transport: http
#   url:       http://localhost:2718/mcp/server (デフォルト)
#
# 環境変数:
#   MARIMO_MCP_URL  既定の MCP URL を上書きしたい場合に指定
set -e

MARIMO_MCP_URL="${MARIMO_MCP_URL:-http://localhost:2718/mcp/server}"

# 冪等性: 既存設定があれば一度消してから追加。
# user スコープで登録し、cwd やセッションに依存しない設定にする。
claude mcp remove --scope user marimo 2>/dev/null || true
if ! claude mcp add --scope user --transport http marimo "${MARIMO_MCP_URL}"; then
    echo "[entrypoint] WARN: marimo MCP server の登録に失敗しました。エージェントは継続して起動します。" >&2
fi

# 登録状況をログに残す(デバッグ用)。
claude mcp list 2>&1 | sed 's/^/[entrypoint] mcp: /' || true

# 本体起動。
exec stdio-to-ws claude-code-acp --port 3017
