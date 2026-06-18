# marimo + AI Agent on Kubernetes

marimo の **エージェント機能(Claude Code / Codex CLI + Ollama / GitHub Copilot CLI)** を、Kubernetes (kind) 上で動かす分析環境。

| Step | 想定 | 説明 |
|---|---|---|
| **Step 1** | 1人で試用 | 1Pod に marimo + ACPサイドカー同居、nginx 前段(:80)で root 配信 |
| **Step 4** | 同一サーバーで複数人並走 PoC | nginx 前段(:80)で path-prefix `/nbN/` 振り分け(Model Y・nip.io 不要) |

| Agent | 推論バックエンド | 認証情報 | ACP port |
|---|---|---|---|
| **Claude Code** | Anthropic (Pro/Max サブスク) | `CLAUDE_CODE_OAUTH_TOKEN`(`claude setup-token`)必須 | 3017 |
| **Codex + Ollama** | 社内/家庭内 Ollama(OpenAI互換) | **不要**(認証情報なし、社内コンプラ対応) | 3021 |
| **GitHub Copilot CLI** | GitHub(Copilot Pro/Business/Enterprise) | `COPILOT_GITHUB_TOKEN`(GitHub PAT、Copilot 利用権限あり) | 3025(Cursor 枠を流用) |

**Step × Agent の 6 組合せすべてが `scripts/bootstrap.sh` のフラグで切替可能**。Copilot CLI は marimo の AGENT_CONFIG で Cursor 用 port 3025 を流用するため、marimo UI 上は「**Cursor**」と表示されるが中身は Copilot CLI(設計詳細: [docs/copilot-agent-design.md](docs/copilot-agent-design.md))。

---

## 使い方(統合 CLI)

```bash
# 1人で試用 + Codex+Ollama(認証情報なし、社内コンプラ対応)
./scripts/bootstrap.sh --step 1 --agent codex

# 1人で試用 + Claude Code
export CLAUDE_CODE_OAUTH_TOKEN='<paste-token-here>'
./scripts/bootstrap.sh --step 1 --agent claude

# 1人で試用 + Copilot CLI(GitHub PAT)
export COPILOT_GITHUB_TOKEN='<paste-pat-here>'
./scripts/bootstrap.sh --step 1 --agent copilot

# 複数人 PoC + Codex+Ollama
./scripts/bootstrap.sh --step 4 --agent codex

# 複数人 PoC + Claude Code
export CLAUDE_CODE_OAUTH_TOKEN='<paste-token-here>'
./scripts/bootstrap.sh --step 4 --agent claude

# 複数人 PoC + Copilot CLI
export COPILOT_GITHUB_TOKEN='<paste-pat-here>'
./scripts/bootstrap.sh --step 4 --agent copilot

# 後片付け
./scripts/teardown.sh
```

ヘルプ: `./scripts/bootstrap.sh --help`

> **切替時の注意**: Step (1↔4) を切替えるときは `teardown.sh` で kind クラスタを再作成する必要がある(kind の extraPortMappings が違うため)。**同じ Step 内で Agent (claude↔codex) を切替える時はクラスタ再作成不要**(両 agent のポートが既に bind されている)。

---

## 設計の核心(全構成共通) — Model Y

marimo 本家のブラウザJSは ACP WebSocket URL を `ws(s)://${hostname}:<agent固有port>/message`(claude=3017 等)で**ハードコード**しており、これが「marimo と ACP を同一ホスト・固定ポートで並べる」制約を生んでいた(旧構成は nip.io や ACP 専用ポート公開でこれを回避していた)。

本リポジトリは **patched marimo**(`ghcr.io/phisignet/marimo-patched`、`getAgentWebSocketUrl` を相対パス `<base>/acp/<agentId>` に改造)を使うことでこの制約を解消する(契約: [docs/acp-relative-ws-handoff.md](docs/acp-relative-ws-handoff.md))。結果:

- **公開ポートは nginx 前段の :80 のみ**。ACP は `<base>/acp/<id>` を :80 経由でサイドカーの `/message` へ中継。
- **テナント分離は path prefix**: `marimo --base-url /nbN` で各テナントを `/nbN/` 配下に配信し、nginx がパスで振り分け。**nip.io / ワイルドカード DNS 不要**。
- Step 1: nginx :80 経由で marimo を root 配信(`/`=marimo、`/acp/<id>`=サイドカー)。
- Step 4: nginx :80 で `/nbN/`=marimo-nbN、`/nbN/acp/<id>`=nbN サイドカー。アクセスは `http://<LAN_IP>/nbN/`。

> 詳細設計は [docs/model-y-design.md](docs/model-y-design.md)。上流 marimo-team/marimo#8531 がマージされたら patched イメージは不要になり公式へ戻せる。

---

## 0. 前提

- Linux + Docker(ログインユーザーが `docker` グループに所属)
- Agent 別:
  - **Claude**: `claude setup-token` で取得した `CLAUDE_CODE_OAUTH_TOKEN`(1年有効)
  - **Codex**: Ollama が `OLLAMA_HOST=0.0.0.0:11434` で起動済、使うモデルが pull 済み。
    加えて `curl` と `python3`(`bootstrap.sh` が Ollama `/api/show` を叩いて
    Codex 用 catalog を生成するのに使う。ほとんどの Linux に標準)
  - **Copilot**: Copilot Pro/Business/Enterprise サブスクに紐づいた GitHub アカウントで
    [Fine-grained PAT を発行](https://github.com/settings/personal-access-tokens/new)
    (**Resource owner = 個人アカウント**、Account → **Copilot Requests** を Read)
    し、`COPILOT_GITHUB_TOKEN` に設定。`github_pat_*` 形式のトークン
    (Classic PAT `ghp_*` は Copilot CLI で**非対応**)
- LAN で他の PC からアクセスしたいなら `hostname -I` で取れる IP を確認

## 1. ツール導入(初回のみ)

```bash
./scripts/install-tools.sh
```
`kind` と `kubectl` を `~/.local/bin` に導入する(sudo 不要)。`--agent codex` を使う場合は別途 `curl` と `python3` を OS パッケージで揃えること(Claude のみなら不要)。

## 2. Ollama 起動(Codex を使う場合のみ)

docker compose 例:
```yaml
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama  # 下記 `docker exec ollama ...` 手順をそのまま使うため
    ports:
      - "11434:11434"
    volumes:
      - ollama:/root/.ollama
volumes:
  ollama:
```

モデル pull(本リポジトリのデフォルトは `gemma4:31b-cloud`):
```bash
docker exec ollama ollama pull gemma4:31b-cloud
# Ollama Cloud (-cloud サフィックス)モデルは事前に `ollama signin` でサインインが必要(無料枠あり)
```

## 3. 起動

```bash
./scripts/bootstrap.sh --step <1|4> --agent <claude|codex|copilot>
```

完了するとアクセスURLが表示される。

## 4. ブラウザでアクセス

| Step | URL |
|---|---|
| Step 1 | `http://localhost/?view-as=present` または `http://<LAN_IP>/?view-as=present` |
| Step 4 | `http://<LAN_IP>/nb1/?view-as=present` / `http://<LAN_IP>/nb2/?view-as=present`(`/nbN/` は自動で `?view-as=present` にリダイレクト) |

公開は nginx 前段の **:80 のみ**(nip.io / 固定 ACP ポート不要)。`?view-as=present` で app view
(コード非表示・出力のみ)で開く。初回は `/workspace/notebook.py` が無ければ自動生成される。

marimo UI を開いたら:
1. **Settings → Lab → "agents" を有効化**(初回のみ。ブラウザ側設定)
2. 左サイドバーのエージェントアイコン
3. `--agent` で起動したものを選ぶ(**claude→Claude / codex→Codex / copilot→Cursor**)
4. ブラウザは `ws(s)://<同じホスト>/[nbN/]acp/<id>` に自動接続(:80 経由・固定ポート不要。HTTP=ws / TLS化時=wss)

> 起動後の操作(エージェントとの協働・marimo-pair・Copilot のモード・事前導入
> パッケージなど)は **[docs/USAGE.md](docs/USAGE.md)** を参照。

---

## ディレクトリ構成

| パス | 役割 |
|---|---|
| `kind/cluster-step1.yaml` | Step 1 用 kind 設定(:80 のみ LAN bind / Model Y) |
| `kind/cluster-step4.yaml` | Step 4 用 kind 設定(:80 のみ LAN bind / Model Y) |
| `images/marimo/Dockerfile` | **patched marimo**(fork)+ `marimo[mcp]` extras + `external_agents` + 分析パッケージ + ノートブック自動起動(`MARIMO_NOTEBOOK`)+ 即時反映(`--watch`/autorun)+ base-url 可変(`MARIMO_BASE_URL`)+ Web 公開無効化(`[sharing]`) |
| `images/acp-agent/` | Claude Code ACP サイドカー(`@anthropic-ai/claude-code` + `@zed-industries/claude-code-acp`)+ marimo-pair skill |
| `images/codex-acp/` | Codex ACP サイドカー(`@openai/codex` + `@zed-industries/codex-acp`)+ marimo-pair skill |
| `images/copilot-acp/` | Copilot CLI ACP サイドカー(`@github/copilot`)+ marimo-pair skill |
| `images/{acp-agent,codex-acp,copilot-acp}/marimo-pair-skill/` | 各 ACP イメージへ vendor した marimo-pair skill |
| `manifests/namespace.yaml` | 専用 namespace `marimo`(全構成共通) |
| `manifests/step1/base/` | Step 1 共通(marimo Deployment + PVC) |
| `manifests/step1/{claude,codex,copilot}/` | Step 1 overlay(サイドカー patch + ClusterIP Service + nginx 前段) |
| `manifests/step4/{claude,codex,copilot}/` | Step 4 フルマニフェスト(nginx path 振り分け + nb1/nb2 テナント、`--base-url /nbN`) |
| `scripts/bootstrap.sh` | 統合 CLI(`--step --agent`) |
| `scripts/teardown.sh` | クラスタ削除(PVC含む) |
| `scripts/install-tools.sh` | kind/kubectl の sudo なしインストール |
| `scripts/lib/common.sh` | 共通関数(LAN_IP 自動推測、cluster 検証、die、Secret 作成等) |
| `scripts/lib/ollama.sh` | Ollama `/api/show` → Codex `model.json` 生成 |
| `scripts/vendor-marimo-pair.sh` | marimo-pair skill を pin tag で各イメージへ vendor(環境固有注記の前置・矛盾セクション除去・サイレント失敗修正を適用) |
| `scripts/test.sh` / `scripts/install-test-tools.sh` | テストランナー(shellcheck + bats)/ テストツール導入(sudo 不要) |
| `tests/` | shellcheck + bats(`lib/*` 関数・bootstrap 引数検証・kustomize build 検証)。詳細は [tests/README.md](tests/README.md) |
| `docs/USAGE.md` | 起動後の利用ガイド(エージェント協働・marimo-pair・モード・パッケージ) |
| `docs/SETUP.md` | 詳細手順とトラブルシューティング |
| `docs/copilot-agent-design.md` | Copilot CLI 統合の設計ドキュメント |

## エージェントが使えるツール

ACPで接続したエージェントは、以下を使ってノートブックを操作・観察できる:

**ACP プロトコル由来**: `Read` / `Edit` / `Write`(marimoノートブック .py の読み書き)

**marimo-pair skill 由来**(全エージェントイメージに焼き込み済み):
- 稼働中の marimo カーネルに **直接コードを実行**(`execute-code.sh` → `/api/kernel/execute`)
- `marimo._code_mode` でセルの作成/編集/削除・実行、パッケージ追加、ウィジェット操作
- ファイル編集より高機能(リッチ表示・カーネル内省・即時反映)。**`code_mode` で作成/編集したセル構造**は `/workspace/notebook.py` に永続化される(一方、`execute-code.sh` の素のスクラッチパッド実行による一時変数・実行結果は永続化されない)
- スキルの配置先: claude=`~/.claude/skills/`、copilot=`~/.copilot/skills/`、codex=`~/.codex/skills/`
- **接続 URL**: Step 1 は `--url http://localhost:2718`。**⚠️ Step 4(Model Y, `--base-url /nbN`)では marimo API も `/nbN/` 配下**になるため `--url http://localhost:2718/nbN` が必要。焼き込んだ SKILL.md は `:2718`(prefix なし)固定のため、**Step 4 での marimo-pair は現状未対応(既知の制約・別 PR で対応予定)**。ファイル編集経由(Read/Edit/Write + `--watch`/autorun)は Step 4 でも動作する。
- バージョン更新: `./scripts/vendor-marimo-pair.sh`(pin tag を取得し3イメージへ再 vendor)

**marimo の MCP サーバー由来**(`--mcp` 有効化済、Pod内で `mcp__marimo__*` として見える):
- `get_notebook_errors` / `get_cell_runtime_data` / `get_cell_outputs` / `get_cell_dependency_graph`
- `get_tables_and_variables` / `get_database_tables`
- `get_marimo_rules` / `lint_notebook`
- プロンプト: `active_notebooks`, `errors_summary`

> marimo の MCP サーバーは marimo の HTTP ポート上 `/mcp/server`(base-url 配下なら `/nbN/mcp/server`)に公開される。Pod 内 ACPサイドカーからの内部呼び出し:
>
> - **Step 1**(root 配信): `http://localhost:2718/mcp/server`
> - **Step 4**(`--base-url /nbN`): `http://localhost:2718/nbN/mcp/server`(claude サイドカーへ `MARIMO_MCP_URL` で注入済み)
>
> Claude Code 構成は起動時に自動登録、Codex 構成は現状未対応。

## Codex + Ollama 特有: 警告抑制(model_catalog_json)

Codex CLI は未知モデルに対して「Model metadata for X not found. Defaulting to fallback metadata」警告を出す([ollama/ollama#14752](https://github.com/ollama/ollama/issues/14752))。bootstrap.sh は Ollama `/api/show` から context_length と capabilities を取得し、Codex の `buildCodexModelEntry` と同じ JSON 構造の model.json を組み立てて ConfigMap `codex-catalog` で注入する。これで警告が完全に消える(Codex 公式の `model_catalog_json` 機構)。

**モデル変更**: `CODEX_MODEL='<新モデル>' ./scripts/bootstrap.sh --step <S> --agent codex` で再実行すれば model.json も自動再生成。

---

## 意図的に妥協している点

- **`--no-token` で marimo 認証なし**: LAN/VPN 前提。Step 4 でも nginx 認証は載せていない(本物の運用に進む時に Basic Auth / OIDC 等を追加)
- **TLS なし(平文 HTTP/WS)**: LAN/VPN 前提
- **MCP エンドポイント `/mcp/server` も認証なしで LAN 公開**: `--no-token` 下で `RequiresEditMiddleware` も素通り
- **patched marimo に依存**: ACP 相対パス化のため fork イメージ(`ghcr.io/phisignet/marimo-patched`)を使用。上流 #8531 マージで公式に戻せる(詳細 [docs/model-y-design.md](docs/model-y-design.md))
- **Step 4 で marimo-pair 未対応**: base-url 配下の API パスに skill が未追従(別 PR で対応予定)。ファイル編集経由は動作

## 関連 Issue / 参考
- marimo Agents 公式: https://docs.marimo.io/guides/editor_features/agents/
- ACP WS 相対パス化(本構成の前提): marimo-team/marimo#8531(プロキシ提案・上流), #6611
- Claude Code Headless 認証: https://code.claude.com/docs/en/authentication
- Codex+Ollama 統合: https://docs.ollama.com/integrations/codex
