# テスト

このプロジェクトは Python を使わず、**シェルスクリプト + Dockerfile + k8s マニフェスト**で
構成される。テストもそれに合わせて以下の構成:

| 種類 | ツール | 対象 |
|---|---|---|
| 静的解析(lint) | **shellcheck** | `scripts/*.sh`, `images/*/entrypoint.sh` |
| ユニットテスト | **bats** | `scripts/lib/*.sh` の関数、`bootstrap.sh` の引数検証 |
| 成果物テスト | **bats** + `kubectl kustomize` | 全 6 overlay(step1/step4 × claude/codex/copilot)が render するか |

> vendored な `images/*/marimo-pair-skill/scripts/*.sh` は upstream 由来のため lint 対象外。

## 実行

```bash
# ツール導入(sudo 不要、~/.local/bin。初回のみ)
./scripts/install-test-tools.sh

# 全テスト(shellcheck + bats)
./scripts/test.sh
```

`shellcheck` / `bats` が無い場合、`test.sh` は該当ステップをスキップする
(`bats` の manifest テストは `kubectl` が無ければ skip)。

## ファイル

| パス | 内容 |
|---|---|
| `tests/common.bats` | `lib/common.sh`: `normalize_url` / `die` / `require_command` / `detect_lan_ip` / `extract_image` |
| `tests/ollama.bats` | `lib/ollama.sh`: `build_codex_model_catalog`(fixture JSON で検証) |
| `tests/bootstrap.bats` | `bootstrap.sh` の引数バリデーション(副作用の無い範囲) |
| `tests/manifests.bats` | 全 overlay の `kubectl kustomize` build |
| `tests/fixtures/` | テスト入力(Ollama `/api/show` 応答サンプル等) |
| `tests/test_helper.bash` | `REPO_ROOT` 解決などの共通ヘルパ |

## 方針(なぜ bats / shellcheck か)

- **shellcheck** は shell の事実上標準の静的解析。未クォート変数や移植性問題を検出する。
- **bats**(bats-core)は bash の事実上標準のユニットテスト FW。
- CI は現状未導入。ローカルで `./scripts/test.sh` を回す運用。
