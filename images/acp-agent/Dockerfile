# ACPサイドカー: stdio-to-ws 越しに @zed-industries/claude-code-acp を起動し、
# marimoブラウザからの WS(ws://HOST:3017/message) を受ける。
#
# 設計上のポイント:
# - npx でランタイム取得すると起動が遅く脆いので、必要パッケージは全て焼き込む。
# - marimo公式イメージは appuser=uid 1000。共有Volumeのパーミッションを揃えるため
#   このイメージも uid 1000 で動かす(同pod fsGroup=1000 と整合)。
# - Claude Codeのサブスク認証は CLAUDE_CODE_OAUTH_TOKEN で渡す(env)。
#   ANTHROPIC_API_KEY は設定しない(設定されると優先されサブスクが無視されるため)。

FROM node:22-slim

# git: Claude Code がリポジトリ文脈を扱う際に必要。
# tini: PID 1 シグナル処理。
# ca-certificates: HTTPS 検証。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        tini \
 && rm -rf /var/lib/apt/lists/*

# ACPスタックを事前インストール(起動時の npx ネットワーク取得を回避)。
# - stdio-to-ws: marimo-team製。NDJSON line framing がデフォルトで ACP に合致。
# - @anthropic-ai/claude-code: Claude Code 本体(claude CLI と Agent SDK)。
# - @zed-industries/claude-code-acp: ACPアダプタ(Claude Code → ACP)。
#   ※ TODO: 本パッケージは @agentclientprotocol/claude-agent-acp へリネーム予定の旨
#     deprecation warning が出る。marimo本家の接続コマンド(state.ts)が
#     依然この旧名を使っているため当面はこのまま使用し、marimo側の移行に追随する。
RUN npm install -g \
        stdio-to-ws@0.2.0 \
        @anthropic-ai/claude-code \
        @zed-industries/claude-code-acp

# node:22-slim には既に node ユーザー (uid/gid 1000) が存在。
# marimo公式イメージの appuser も uid/gid 1000 なので、ID整合のためそのまま流用する。
USER node
WORKDIR /workspace

EXPOSE 3017

# stdio-to-ws の使い方:
#   stdio-to-ws "<command-string>" --port <port>
# 第1引数は単一の文字列としてサブコマンドを受け取る(README参照)。
# claude-code-acp は globally install 済みで /usr/local/bin にバイナリがあるため
# npx を介さず直接起動(起動の高速化と依存の単純化)。
ENTRYPOINT ["tini", "--"]
CMD ["stdio-to-ws", "claude-code-acp", "--port", "3017"]
