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
out = "".join(lines[:insert_at]) + note + "\n" + "".join(lines[insert_at:])
open(path, "w", encoding="utf-8").write(out)
PY

    # バージョンを記録(再現性の証跡)
    echo "$MARIMO_PAIR_VERSION" > "$dest/.vendored-version"
done

echo "[vendor] 完了。git diff を確認してコミットしてください(version=${MARIMO_PAIR_VERSION})。"
