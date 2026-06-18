# patched marimo イメージを継承し、MCPサーバー extras を有効化した派生イメージ。
#
# ★ ベースは公式ではなく自前 fork のパッチ済みイメージ:
#   ghcr.io/phisignet/marimo-patched:<version>
#   ACP WebSocket 接続先を相対パス(<base>/acp/<agentId>)に変更したフロントを焼いてある
#   (docs/acp-relative-ws-handoff.md §2 が契約)。これにより固定ポート(3017等)が不要になり、
#   単一ホスト/ポートで path-prefix によるマルチテナント(Model Y)が成立する。
#   公式イメージ相当の drop-in(USER appuser uid1000 / site-packages 所有も同じ)。
#
# 派生する理由:
# - 公式/patched とも marimo[mcp] extras は含まないため、ここで追加する
#   → extras を入れると http://localhost:PORT/mcp/server に MCP サーバーが立ち、
#     ACPエージェント(同Pod内)から get_notebook_errors 等の高機能ツールが叩ける
#
# 再現性のため、base image と extras インストールの双方で同一の MARIMO_VERSION を参照する。
# バージョン上げ時は fork 側で patched タグを作り直し + 本構成を再検証した上で ARG を書き換える。
ARG MARIMO_VERSION=0.23.8
FROM ghcr.io/phisignet/marimo-patched:${MARIMO_VERSION}

# FROM を跨ぐと ARG は再宣言が必要(Dockerfileの仕様)。
ARG MARIMO_VERSION

# mcp extras を base と同じバージョンで pin して入れる。
# patched marimo が既に同バージョンで入っているため、pip は marimo 本体を再インストールせず
# (== で満たされる)、mcp extras の依存だけ追加する → パッチ済み _static は温存される。
RUN pip install --no-cache-dir "marimo[mcp]==${MARIMO_VERSION}"

# 念のため、extras インストール後も relative-path パッチ(/acp/)が _static に残っているか検証。
# 万一 pip が marimo 本体を上書きしてパッチが消えた場合は build をここで失敗させる(サイレント劣化防止)。
RUN grep -rq "/acp/" /usr/local/lib/python*/site-packages/marimo/_static/assets/ \
 || (echo "ERROR: relative-path patch (/acp/) が _static に見つかりません。base が patched イメージか、pip がパッチを上書きしていないか確認してください。" >&2; exit 1)

# データ分析でよく使うライブラリを事前インストール。
# カーネル(このコンテナ)でセルを実行する際、エージェント/ユーザーが毎回
# ctx.packages.add() や pip で入れる手間とインストール待ちを省く。
# marimo-pair の code_mode でも import がそのまま通る。
# 未 pin(範囲指定なし)= base イメージの Python に対する最新解決。再現性が
# 必要になったらここで個別 pin する設計。
#
# root で入れる理由: 一部パッケージ(altair/nbformat 系)が root 所有の
# /usr/local/share/jupyter にデータファイルを書くため、appuser のままだと
# Permission denied になる。インストール後、site-packages / bin / share を
# appuser に chown し直し、ランタイムの ctx.packages.add() / pip が引き続き
# 書き込めるようにする(base イメージの所有設計を維持)。
USER root
RUN pip install --no-cache-dir \
        numpy \
        pandas \
        matplotlib \
        seaborn \
        altair \
        plotly \
        polars \
        pyarrow \
        scikit-learn \
        scipy \
        statsmodels \
 && chown -R appuser:appuser \
        /usr/local/lib/python*/site-packages \
        /usr/local/bin \
        /usr/local/share
USER appuser

# 初期 marimo user config を焼き込み:
#   [experimental] external_agents = true
#     ブラウザの Settings → Lab で毎回手動で有効化する手間を省く。
#   [runtime] watcher_on_save = "autorun"
#     ファイル変更を検知して該当セルを自動実行(--watch と併用)。
#   [sharing] html = false / wasm = false
#     ノートブックを外部(static.marimo.app / WASM / molab)へ公開する UI を隠す。
#     publish/share はブラウザから外部へ直接送信される=社内データ漏洩経路になるため、
#     社内展開のデフォルトとして無効化(marimo 公式の SharingConfig)。
#     必要になったら該当行を true に戻す or marimo.toml で上書きする。
# パスは marimo 0.23.8 の `marimo config show` で実機確認した
# /home/appuser/.config/marimo/marimo.toml(=$HOME/.config/marimo/marimo.toml)。
# ファイル所有を appuser にして、ランタイムでの追加設定変更(他フラグ等)も
# marimo が同じファイルに書き戻せるようにする(read-write のままにする)。
RUN mkdir -p /home/appuser/.config/marimo \
 && printf '[experimental]\nexternal_agents = true\n\n[runtime]\nwatcher_on_save = "autorun"\n\n[sharing]\nhtml = false\nwasm = false\n' \
        > /home/appuser/.config/marimo/marimo.toml

# 公式CMDは:
#   sh -c "exec marimo edit --no-token -p $PORT --host $HOST"
#
# 本構成では以下の方針:
# - --mcp は常にON(MCPサーバーがこのプロジェクトの存在意義)
# - --mcp-allow-remote は **デフォルトOFF**。env MARIMO_ALLOW_REMOTE_MCP=1
#   が設定された時だけ付与する opt-in 方式。
#
# 理由: --mcp-allow-remote は DNS rebinding 保護(Hostヘッダ検査)を無効化する。
# 同Pod内ACPサイドカーは `http://localhost:2718/mcp/server` に Host=localhost
# で繋ぐので無効化しなくても通る(2026-05実機検証済)。
# nginx 等の前段ホスト名で受ける構成に拡張する際だけ env で有効化する。
# MARIMO_NOTEBOOK: 起動時に開くノートブックのパス(デフォルト: /workspace/notebook.py)。
# ファイルが存在しない場合は marimo が自動作成する。
# ファイル名を指定しないとホーム画面が開きエージェントとチャットを始められないため必須。
#
# MARIMO_BASE_URL: marimo をパスプレフィックス配下で配信する(例: /nb1)。
#   Model Y(path-prefix マルチテナント)の Step 4 で各テナントに別 prefix を割り当てる。
#   空(Step 1)なら --base-url を付けず root 配信。先頭は "/" 始まり(marimo の仕様)。
#   ⚠️ base-url 配下では healthz も <base>/healthz になるため、readinessProbe の path を
#      合わせること(manifest 側で設定)。
ENV MARIMO_ALLOW_REMOTE_MCP=""
ENV MARIMO_NOTEBOOK="/workspace/notebook.py"
ENV MARIMO_BASE_URL=""
CMD ["sh", "-c", "ALLOW=; [ \"$MARIMO_ALLOW_REMOTE_MCP\" = \"1\" ] && ALLOW=\"--mcp-allow-remote\"; BASE=; [ -n \"$MARIMO_BASE_URL\" ] && BASE=\"--base-url $MARIMO_BASE_URL\"; exec marimo edit --no-token --mcp --watch $ALLOW $BASE -p $PORT --host $HOST \"$MARIMO_NOTEBOOK\""]
