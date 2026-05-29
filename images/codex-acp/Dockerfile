# Codex ACPサイドカー: stdio-to-ws 越しに @zed-industries/codex-acp を起動し、
# marimoブラウザからの WS(ws://HOST:3021/message) を受ける。
#
# Claude 版 (images/acp-agent/Dockerfile) と双子の構成。違いは:
# - npm pkg: @openai/codex + @zed-industries/codex-acp
# - port: 3021 (marimo state.ts の Codex 固定 port)
# - 認証: API キー不要(Ollama 等 OpenAI互換 base_url 向け、
#         model_providers.X.requires_openai_auth = false でバイパス)
# - 起動時に ~/.codex/config.toml を env から動的生成
#
# 設計上のポイント:
# - npx でランタイム取得すると起動が遅く脆いので、必要パッケージは全て焼き込む。
# - node ユーザー(uid 1000)= marimo公式イメージの appuser と整合。

FROM node:22-slim

# git: Codex がリポジトリ文脈を扱う際に必要。
# tini: PID 1 シグナル処理。
# ca-certificates: HTTPS 検証。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        tini \
        curl \
        jq \
 && rm -rf /var/lib/apt/lists/*

# Codex スタックを事前インストール(起動時の npx ネットワーク取得を回避)。
# - stdio-to-ws@0.2.0: marimo-team製。NDJSON line framing がデフォルトで ACP に合致。
# - @openai/codex: Codex CLI 本体。
# - @zed-industries/codex-acp: ACPアダプタ(Codex → ACP)。
#
# バージョンを patch まで pin して再現性確保。バージョン上げ時は:
#   1) Ollama+Codex 連携の最新 issue(ollama/ollama#14752 等)を確認
#   2) 実機で警告抑制 / wire_api / config 形式に互換性問題が無いか検証
#   3) PR 本文の version 記述と合わせて更新
RUN npm install -g \
        stdio-to-ws@0.2.0 \
        @openai/codex@0.133.0 \
        @zed-industries/codex-acp@0.15.0

# 起動時に ~/.codex/config.toml を env から動的生成するエントリポイント。
COPY --chown=node:node entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# marimo-pair skill を Codex の skill ディレクトリへ配置。
# Codex は ~/.codex/skills/ から skill をロードする(marimo 公式 pair サポート対象)。
# スキルは scripts/vendor-marimo-pair.sh で pin 取得済み(.vendored-version 参照)。
# curl/jq は execute-code.sh が marimo の HTTP API を叩くのに必要(上の apt で導入済)。
COPY --chown=node:node marimo-pair-skill /home/node/.codex/skills/marimo-pair

USER node
WORKDIR /workspace

EXPOSE 3021

# entrypoint.sh が:
#   1) ~/.codex/config.toml を env (OLLAMA_BASE_URL, CODEX_MODEL 等) から生成
#   2) exec stdio-to-ws codex-acp --port 3021
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
