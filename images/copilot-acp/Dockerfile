# ACPサイドカー(Copilot): stdio-to-ws 越しに `copilot --acp --stdio` を起動し、
# marimoブラウザからの WS(ws://HOST:3025/message) を受ける。
#
# marimo の AGENT_CONFIG では port 3025 は Cursor 用に予約されているが、
# 同 ACP プロトコルなので「Cursor を選ぶ → 中身は Copilot」という流用が成立する
# (公式チュートリアル: OpenCode を Claude port 3017 に乗せる事例と同型)。
#
# 設計上のポイント:
# - claude/codex 構成と同様、npx ランタイム取得は避けて全部焼き込む。
# - 共有Volumeのパーミッションを揃えるため uid 1000(node ユーザー)で動かす
#   (marimo公式イメージの appuser=uid 1000、fsGroup=1000 と整合)。
# - GitHub Copilot の認証は COPILOT_GITHUB_TOKEN(GitHub PAT)で env 経由のみ。
#   `~/.copilot/config.json` は headless で挙動が不安定(2026-05 時点 v1.0.54)
#   なので env のみ運用に統一する。

FROM node:22-slim

# tini: PID 1 シグナル処理。
# ca-certificates: HTTPS 検証(Copilot API は GitHub の HTTPS エンドポイント)。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        tini \
        curl \
        jq \
 && rm -rf /var/lib/apt/lists/*

# ACPスタックを事前インストール。
# - stdio-to-ws: marimo-team製、NDJSON line framing で ACP に合致。
# - @github/copilot: GitHub Copilot CLI 本体(`copilot --acp --stdio` を提供)。
#   ACP サポートは 2026-01-28 public preview([GitHub Changelog])。
#   バージョン pin の理由: public preview 期間中で破壊的変更可能性があるため。
RUN npm install -g \
        stdio-to-ws@0.2.0 \
        @github/copilot@1.0.54

# uid 1000(node)で動かす。Claude/Codex 構成と同じ流儀。
COPY --chown=node:node entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# marimo-pair skill を Copilot CLI の personal skill ディレクトリへ配置。
# Copilot CLI は ~/.copilot/skills/ から skill をロードし、ACP クライアント上でも
# slash command として利用可能(@github/copilot changelog 参照)。
# スキルは scripts/vendor-marimo-pair.sh で pin 取得済み(.vendored-version 参照)。
# curl/jq は execute-code.sh が marimo の HTTP API を叩くのに必要(上の apt で導入済)。
COPY --chown=node:node marimo-pair-skill /home/node/.copilot/skills/marimo-pair

USER node
WORKDIR /workspace

EXPOSE 3025

# entrypoint.sh が COPILOT_GITHUB_TOKEN 確認 → stdio-to-ws + `copilot --acp --stdio`
# を起動する。tini は PID 1 として子プロセスのシグナル処理を担当。
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
