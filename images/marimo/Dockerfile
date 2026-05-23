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
FROM ghcr.io/marimo-team/marimo:latest

# 既存の marimo インストールに mcp extras だけ追加する形になる。
# (marimo パッケージ自体は再インストールされない/同バージョン維持)
RUN pip install --no-cache-dir --user --no-warn-script-location \
        "marimo[mcp]" \
 || pip install --no-cache-dir "marimo[mcp]"
# ↑ 環境によって --user / system のどちらが効くか変わるため両方試行。
#   appuser が /usr/local/lib/.../site-packages を所有しているのでどちらでも入る。

# 公式CMDは:
#   sh -c "exec marimo edit --no-token -p $PORT --host $HOST"
# これに --mcp(MCPサーバー有効化)と --mcp-allow-remote(DNSリバインディング
# 保護を無効化。同Pod内localhost通信でもHostヘッダ検査で蹴られる可能性を排除)
# を加える。
CMD ["sh", "-c", "exec marimo edit --no-token --mcp --mcp-allow-remote -p $PORT --host $HOST"]
