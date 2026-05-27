# marimo + AI Agent on Kubernetes

marimo の **エージェント機能(Claude Code / Codex CLI + Ollama / GitHub Copilot CLI)** を、Kubernetes (kind) 上で動かす分析環境。

| Step | 想定 | 説明 |
|---|---|---|
| **Step 1** | 1人で試用 | 1Pod に marimo + ACPサイドカー同居、ポートを LAN に直接公開 |
| **Step 4** | 同一サーバーで複数人並走 PoC | nginx 前段で Hostヘッダ振り分け + nip.io ワイルドカードDNS |

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

## 設計の核心(全構成共通)

marimo のブラウザJSは ACP の WebSocket URL を `ws(s)://${window.location.hostname}:<port>/message` でハードコードする([`frontend/src/components/chat/acp/state.ts`](https://github.com/marimo-team/marimo/blob/main/frontend/src/components/chat/acp/state.ts) の `getAgentWebSocketUrl`)。port は agentId 別に固定:

- Claude Code = **3017**
- Codex CLI = **3021**
- Cursor = **3025**(本リポジトリでは Copilot CLI を流用)
- Gemini = 3019, OpenCode = 3023(未対応)

そのため marimo (HTTP 2718 or 80) と ACP の port を「**同じホスト名/IP に揃えて**」公開する必要がある。これが本リポジトリ全体の最重要制約。

- Step 1: 同一 LAN_IP 上に :2718 と :3017/:3021/:3025 を NodePort で並べる
- Step 4: nginx が :80 と :3017/:3021/:3025 を Listen し、Hostヘッダで Pod を振り分け(`nb1.<IP>.nip.io` / `nb2.<IP>.nip.io`)

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
./scripts/bootstrap.sh --step <1|4> --agent <claude|codex>
```

完了するとアクセスURLが表示される。

## 4. ブラウザでアクセス

| Step | URL |
|---|---|
| Step 1 | `http://localhost:2718/` または `http://<LAN_IP>:2718/` |
| Step 4 | `http://nb1.<LAN_IP>.nip.io/` / `http://nb2.<LAN_IP>.nip.io/` |

marimo UI を開いたら:
1. **Settings → Lab → "agents" を有効化**(初回のみ。ブラウザ側設定)
2. 左サイドバーのエージェントアイコン
3. **Claude / Codex** を選択(`--agent` で起動したものを選ぶ)
4. ブラウザは `ws://<同じホスト>:<port>/message` に自動接続(`<port>` は claude=3017 / codex=3021)

---

## ディレクトリ構成

| パス | 役割 |
|---|---|
| `kind/cluster-step1.yaml` | Step 1 用 kind 設定(2718 + 3017 + 3021 + 3025 を LAN bind) |
| `kind/cluster-step4.yaml` | Step 4 用 kind 設定(80 + 3017 + 3021 + 3025 を LAN bind) |
| `images/marimo/Dockerfile` | marimo 公式 + `marimo[mcp]` extras + `external_agents` 初期有効化 |
| `images/acp-agent/` | Claude Code ACP サイドカー(`@anthropic-ai/claude-code` + `@zed-industries/claude-code-acp`) |
| `images/codex-acp/` | Codex ACP サイドカー(`@openai/codex` + `@zed-industries/codex-acp`) |
| `images/copilot-acp/` | Copilot CLI ACP サイドカー(`@github/copilot`) |
| `manifests/namespace.yaml` | 専用 namespace `marimo`(全構成共通) |
| `manifests/step1/base/` | Step 1 共通(marimo Deployment + PVC) |
| `manifests/step1/{claude,codex,copilot}/` | Step 1 の agent 別 overlay(Kustomize、サイドカー patch + Service) |
| `manifests/step4/{claude,codex,copilot}/` | Step 4 の agent 別フルマニフェスト(nginx + nb1/nb2 テナント) |
| `scripts/bootstrap.sh` | 統合 CLI(`--step --agent`) |
| `scripts/teardown.sh` | クラスタ削除(PVC含む) |
| `scripts/install-tools.sh` | kind/kubectl の sudo なしインストール |
| `scripts/lib/common.sh` | 共通関数(LAN_IP 自動推測、cluster 検証、die、Secret 作成等) |
| `scripts/lib/ollama.sh` | Ollama `/api/show` → Codex `model.json` 生成 |
| `docs/SETUP.md` | 詳細手順とトラブルシューティング |
| `docs/copilot-agent-design.md` | Copilot CLI 統合の設計ドキュメント |

## エージェントが使えるツール

ACPで接続したエージェントは、以下を使ってノートブックを操作・観察できる:

**ACP プロトコル由来**: `Read` / `Edit` / `Write`(marimoノートブック .py の読み書き)

**marimo の MCP サーバー由来**(`--mcp` 有効化済、Pod内で `mcp__marimo__*` として見える):
- `get_notebook_errors` / `get_cell_runtime_data` / `get_cell_outputs` / `get_cell_dependency_graph`
- `get_tables_and_variables` / `get_database_tables`
- `get_marimo_rules` / `lint_notebook`
- プロンプト: `active_notebooks`, `errors_summary`

> marimo の MCP サーバーは marimo 自身の HTTP ポート上の `/mcp/server` に公開される。アクセス経路は構成で変わる:
>
> - **Step 1**: `http://<LAN_IP>:2718/mcp/server`(NodePort 経由)
> - **Step 4**: `http://nb<N>.<LAN_IP>.nip.io/mcp/server`(nginx 経由でテナント別 Pod に振り分け)
> - **Pod 内 ACPサイドカーからの内部呼び出し**: `http://localhost:2718/mcp/server`(Step 1/4 共通、コンテナ間 localhost)
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
- **Step 4: nip.io 公開DNS依存**: 名前は世界中から見えるが、解決先がLANのプライベートIPなので外部から到達不可。気になる場合は家庭内 dnsmasq / ルーター静的DNS に切替可能(Service宛先は不変)

## 関連 Issue / 参考
- marimo Agents 公式: https://docs.marimo.io/guides/editor_features/agents/
- 3017 ハードコード関連: marimo-team/marimo#8531(プロキシ提案・未実装), #6611
- Claude Code Headless 認証: https://code.claude.com/docs/en/authentication
- Codex+Ollama 統合: https://docs.ollama.com/integrations/codex
- nip.io: https://nip.io/
