# marimo 公式イメージを継承し、MCPサーバー extras を有効化した派生イメージ。
#
# 派生する理由:
# - 公式 ghcr.io/marimo-team/marimo:latest は marimo[mcp] extras を含まない
#   → `marimo edit --mcp` フラグが --help にも現れず使えない
# - extras を入れると http://localhost:PORT/mcp/server に MCP サーバーが立ち、
#   ACPエージェント(同Pod内)から get_notebook_errors 等の高機能ツールが叩ける
#
# 公式イメージの構成:
# - USER appuser (uid/gid 1000)、WORKDIR /app
# - site-packages と /usr/local/bin は appuser 所有なので、root昇格なしで
#   pip install が成功する。
#
# 再現性のため、base image と extras インストールの双方で同一の
# MARIMO_VERSION を参照する(:latest や unpinned だと upstream 変更で
# build が壊れうる。特に本ファイルが依拠する --mcp は experimental flag)。
# バージョン上げ時は実機検証(--mcp-allow-remote 無しで繋がるか含む)した上で
# ここの ARG だけ書き換えれば良い設計。
ARG MARIMO_VERSION=0.23.8
FROM ghcr.io/marimo-team/marimo:${MARIMO_VERSION}

# FROM を跨ぐと ARG は再宣言が必要(Dockerfileの仕様)。
ARG MARIMO_VERSION

# mcp extras を base と同じバージョンで pin して入れる。
# 未 pin だと marimo 自体が silent に upgrade されて base image とのズレや
# --mcp の hidden 仕様変更を踏むリスクがある。
RUN pip install --no-cache-dir "marimo[mcp]==${MARIMO_VERSION}"

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
# ブラウザの Settings → Lab で毎回手動で有効化する手間を省く。
# パスは marimo 0.23.8 の `marimo config show` で実機確認した
# /home/appuser/.config/marimo/marimo.toml(=$HOME/.config/marimo/marimo.toml)。
# ファイル所有を appuser にして、ランタイムでの追加設定変更(他フラグ等)も
# marimo が同じファイルに書き戻せるようにする(read-write のままにする)。
RUN mkdir -p /home/appuser/.config/marimo \
 && printf '[experimental]\nexternal_agents = true\n\n[runtime]\nwatcher_on_save = "autorun"\n' \
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
ENV MARIMO_ALLOW_REMOTE_MCP=""
ENV MARIMO_NOTEBOOK="/workspace/notebook.py"
CMD ["sh", "-c", "ALLOW=; [ \"$MARIMO_ALLOW_REMOTE_MCP\" = \"1\" ] && ALLOW=\"--mcp-allow-remote\"; exec marimo edit --no-token --mcp --watch $ALLOW -p $PORT --host $HOST \"$MARIMO_NOTEBOOK\""]
