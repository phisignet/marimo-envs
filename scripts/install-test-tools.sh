#!/usr/bin/env bash
# テスト用ツール(shellcheck / bats)を ~/.local/bin に sudo なしで導入する。
# install-tools.sh と同じ流儀。既にあれば何もしない。
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

case ":$PATH:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "WARN: ${BIN_DIR} が PATH に含まれていない。シェル設定で追加してください。" >&2 ;;
esac

SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-v0.10.0}"
BATS_VERSION="${BATS_VERSION:-v1.13.0}"

# ----- shellcheck(静的解析。プリビルドバイナリ) -----
if command -v shellcheck >/dev/null 2>&1; then
  echo "[=] shellcheck already installed: $(shellcheck --version | awk '/version:/{print $2}')"
else
  echo "[+] Installing shellcheck ${SHELLCHECK_VERSION} → ${BIN_DIR}/shellcheck"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL \
    "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | tar -xJ -C "$tmp"
  install -m 0755 "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "${BIN_DIR}/shellcheck"
fi

# ----- bats(bash テスト FW。pure shell) -----
if command -v bats >/dev/null 2>&1; then
  echo "[=] bats already installed: $(bats --version)"
else
  echo "[+] Installing bats ${BATS_VERSION} → ${BIN_DIR%/bin} (prefix)"
  tmp_bats="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}" "$tmp_bats"' EXIT
  git clone --quiet --depth 1 --branch "$BATS_VERSION" \
    https://github.com/bats-core/bats-core.git "$tmp_bats/bats-core"
  # install.sh は <prefix>/bin に bats を置く。BIN_DIR の親を prefix にする。
  "$tmp_bats/bats-core/install.sh" "${BIN_DIR%/bin}"
fi

echo "[ok] test tools ready. 実行: ./scripts/test.sh"
