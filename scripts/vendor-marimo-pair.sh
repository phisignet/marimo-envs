#!/usr/bin/env bash
# marimo-pair skill を各 ACP イメージのビルドコンテキストへ vendor(焼き込み)する。
#
# 背景:
#   docker build のコンテキストは images/<agent>/ 単位なので、共有スキルを
#   COPY するには各イメージディレクトリ内にファイルが存在する必要がある。
#   ビルド時ネットワーク非依存 + 完全再現性のため、スキルをリポジトリへ
#   コミットする方針。本スクリプトは pinned tag から取得して各 image dir へ
#   配置し、この環境固有のセットアップ注記を SKILL.md へ前置する。
#
# 使い方:
#   ./scripts/vendor-marimo-pair.sh          # 既定バージョンで vendor
#   MARIMO_PAIR_VERSION=v0.0.16 ./scripts/vendor-marimo-pair.sh
#
# 実行後は git diff を確認してコミットすること。
set -euo pipefail

MARIMO_PAIR_VERSION="${MARIMO_PAIR_VERSION:-v0.0.15}"
REPO_URL="https://github.com/marimo-team/marimo-pair.git"
SKILL_SUBPATH="skills/marimo-pair"

# このリポジトリのルート(scripts/ の親)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# vendor 先: 各 ACP イメージ dir の marimo-pair-skill/
DEST_DIRS=(
  "$ROOT/images/acp-agent/marimo-pair-skill"
  "$ROOT/images/codex-acp/marimo-pair-skill"
  "$ROOT/images/copilot-acp/marimo-pair-skill"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "[vendor] clone ${REPO_URL} @ ${MARIMO_PAIR_VERSION}"
git clone --quiet --depth 1 --branch "$MARIMO_PAIR_VERSION" "$REPO_URL" "$tmp/marimo-pair"

src="$tmp/marimo-pair/$SKILL_SUBPATH"
if [ ! -f "$src/SKILL.md" ]; then
    echo "[vendor] ERROR: $src/SKILL.md が見つかりません。サブパス構成が変わった可能性があります。" >&2
    exit 1
fi

# この環境固有の注記(SKILL.md の frontmatter 直後に挿入する本文)。
# discovery はコンテナ跨ぎで使えないため --url を強制する。
read -r -d '' SETUP_NOTE <<'NOTE' || true

## ⚠️ この環境固有のセットアップ(最優先・必読)

この marimo は Kubernetes Pod 内で常時起動済みです:

- **URL: `http://localhost:2718`**(同一 Pod 内・`--no-token`)
- すでに起動済み。**新しい marimo サーバーを起動しないこと。**

**サーバー discovery(レジストリ自動検出)は使えません。** agent と marimo は
別コンテナで、レジストリファイルを共有していないためです。`discover-servers.sh`
は常に空を返します。コード実行時は必ず `--url http://localhost:2718` を明示してください:

```bash
bash scripts/execute-code.sh --url http://localhost:2718 -c "1 + 1"
```

複数行コードは heredoc を使ってください:

```bash
bash scripts/execute-code.sh --url http://localhost:2718 <<'EOF'
import marimo._code_mode as cm
async with cm.get_context() as ctx:
    ctx.create_cell("x = 1")
EOF
```

NOTE

for dest in "${DEST_DIRS[@]}"; do
    echo "[vendor] -> $dest"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -r "$src/." "$dest/"

    # SKILL.md の frontmatter(2つ目の '---')直後に注記を挿入。
    skill_md="$dest/SKILL.md"
    python3 - "$skill_md" "$SETUP_NOTE" <<'PY'
import sys
path, note = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
# frontmatter の終端('---' のみの行、2回目)を探す
dash_count = 0
insert_at = None
for i, line in enumerate(lines):
    if line.strip() == "---":
        dash_count += 1
        if dash_count == 2:
            insert_at = i + 1
            break
if insert_at is None:
    print(f"ERROR: frontmatter terminator not found in {path}", file=sys.stderr)
    sys.exit(1)
text = "".join(lines[:insert_at]) + note + "\n" + "".join(lines[insert_at:])

# upstream の discovery/サーバー起動セクションを除去する。
# この環境では discovery は常に空(別コンテナ)・marimo は常時起動済みのため、
# 「No servers running? → start one」等の手順は冒頭注記(--url 必須・新規起動禁止)
# と矛盾する。該当 '###' セクションを次の見出しまで削除する。
# best-effort: 見つからなくても警告のみ(冒頭注記が最終的な権威)。
remove_titles = [
    "### Discovery finds nothing but the user has a server running?",
    "### No servers running?",
]
out_lines = text.splitlines(keepends=True)
for title in remove_titles:
    start = next((i for i, ln in enumerate(out_lines) if ln.strip() == title), None)
    if start is None:
        print(f"WARN: section '{title}' not found in {path} (upstream 変更?)", file=sys.stderr)
        continue
    # 次の見出し(## / ###)または無関係な後続トピック(**Avoid… 等の太字段落)
    # まで削除。discovery/サーバー起動の記述だけに絞り、heredoc 例などの有用な
    # 後続コンテンツを巻き込まないようにする。
    end = len(out_lines)
    for j in range(start + 1, len(out_lines)):
        ln = out_lines[j]
        if ln.startswith("## ") or ln.startswith("### ") or ln.startswith("**"):
            end = j
            break
    del out_lines[start:end]
open(path, "w", encoding="utf-8").write("".join(out_lines))
PY

    # execute-code.sh のサイレント失敗を修正(ローカルパッチ)。
    # upstream v0.0.15 では curl が process substitution 内のため set -e で
    # 失敗が伝播せず、`done` イベントが来ずにストリームが終わっても exit_code=0
    # のまま成功扱いになる(HTTP エラー / サーバークラッシュ / 接続断時)。
    # エージェントが失敗を成功と誤認するため、ループ後に done_received を検査して
    # 受信していなければ非0終了させる。upstream に修正が入ったら不要になる。
    exec_sh="$dest/scripts/execute-code.sh"
    python3 - "$exec_sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = 'exit "$exit_code"'
guard = (
    'if [[ "$done_received" == false ]]; then\n'
    '  echo "Error: marimo kernel stream ended without a \'done\' event '
    '(server unreachable, HTTP error, or kernel crash)." >&2\n'
    '  exit 1\n'
    'fi\n'
)
if "done_received\" == false ]]; then\n  echo \"Error: marimo kernel stream ended" in text:
    sys.exit(0)  # 既にパッチ済み
if anchor not in text:
    print(f"ERROR: anchor '{anchor}' not found in {path}. upstream の構造変更の可能性。", file=sys.stderr)
    sys.exit(1)
# 最後の `exit "$exit_code"` の直前に guard を挿入
idx = text.rfind(anchor)
patched = text[:idx] + guard + text[idx:]
open(path, "w", encoding="utf-8").write(patched)
PY

    # バージョンを記録(再現性の証跡)
    echo "$MARIMO_PAIR_VERSION" > "$dest/.vendored-version"
done

echo "[vendor] 完了。git diff を確認してコミットしてください(version=${MARIMO_PAIR_VERSION})。"
