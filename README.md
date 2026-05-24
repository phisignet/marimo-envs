# marimo + Codex (Ollama) on Kubernetes

marimo の **エージェント機能(Codex CLI + Ollama)** を、Kubernetes (kind) 上で動かす分析環境。
本ブランチ `feat/codex-ollama` は Step 1 を Claude Code から **Codex CLI + Ollama** に置き換えた構成。
推論バックエンドが社内ホスト/家庭内 Ollama になるため、**API キー / OpenAI 課金は不要**(社内コンプラ的にも閉じる)。

> Claude Code 構成(`scripts/bootstrap.sh` がサブスクトークン要求)は main にあり。本ブランチではそれを置き換え。

| Step | 想定 | エージェント | アクセス | bootstrap |
|---|---|---|---|---|
| **Step 1** | 1人で試用 | **Codex + Ollama**(本ブランチ) | `http://<LAN_IP>:2718/` ※port 3021 で ACP | `scripts/bootstrap.sh` |
| Step 4 (PoC) | 同一サーバーで複数人並走(Claude構成) | Claude Code | `http://nbN.<LAN_IP>.nip.io/` | `scripts/bootstrap-step4.sh` |

## Codex+Ollama を選ぶ理由

- **認証情報不要**: Codex CLI の `~/.codex/config.toml` で `requires_openai_auth=false`(implicit)+ Ollama 経由なので API キーなしで動く
- **社内データが外に出ない**: 推論は社内/家庭内 Ollama のみ。OpenAI 等への通信は一切なし(`/api/show` の応答時間や Ollama ログで検証可能)
- **Claude サブスクへの依存も外す**: 会社で個人サブスクを使えない/通せない環境向け

## 設計の核心(全構成共通)

marimo のブラウザJSは ACP の WebSocket URL を
`ws(s)://${window.location.hostname}:<port>/message` でハードコードしている
(`frontend/src/components/chat/acp/state.ts` の `getAgentWebSocketUrl`)。
port は `agentId` 別に固定:

- Claude Code = **3017**(main 構成)
- **Codex = 3021**(本ブランチ構成)
- Gemini = 3019, OpenCode = 3023, Cursor = 3025

そのため marimo (HTTP 2718) と ACP (Codex=3021) を「同じホスト名/IP」に揃えて公開する必要がある。これが本リポジトリの最重要制約。

- Step 1: 同一 LAN_IP 上に :2718 と :3021 を NodePort で並べる(本ブランチで :3017 → :3021 に変更)

---

# Step 1: 1人での試用

## 構成図(Step 1)

```
ブラウザ
  │ ① http://HOST:2718/        marimo UI / marimo自身のWebSocket
  │ ② ws://HOST:3017/message   ACPエージェントへ直結
  ▼
┌─ Service (NodePort, marimo namespace) ───────────────┐
│   2718 → nodePort 30718        3017 → nodePort 30317 │
└──────────────────────────────────────────────────────┘
                              │
                kind extraPortMappings (LAN公開)
                              │
┌─ Pod ────────────────────────────────────────────────┐
│  [marimo container]            [acp-agent container] │
│   marimo edit :2718             stdio-to-ws :3017    │
│                                  └ claude-code-acp   │
│                                     └ Claude Code SDK│
│            └── 共有Volume(PVC) /workspace ──┘        │
└──────────────────────────────────────────────────────┘
```

## クイックスタート(Step 1)

### 0. 前提
- Linux + Docker(ログインユーザーが `docker` グループに所属)
- Claude Pro / Max サブスク
- LANで到達したいなら `hostname -I` で取れる IP を確認

### 1. ツール導入(初回のみ)
```bash
./scripts/install-tools.sh
```
`kind` と `kubectl` を `~/.local/bin` に導入する(sudo不要)。

### 2. Ollama を立てて 0.0.0.0 で listen させる

家のマシン or 社内サーバーで Ollama を起動。Pod から到達可能にするため必ず `OLLAMA_HOST=0.0.0.0:11434` で listen させる。
docker compose 例:

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    ports:
      - "11434:11434"
    volumes:
      - ollama:/root/.ollama
volumes:
  ollama:
```

モデルを pull(本リポジトリのデフォルトは `gemma4:31b-cloud`):
```bash
docker exec ollama ollama pull gemma4:31b-cloud
# Ollama Cloud (-cloud サフィックス)モデルは事前に `ollama signin` でサインインが必要(無料枠あり)
```

### 3. デプロイ
```bash
# OLLAMA_BASE_URL を指定(Pod から到達できる URL=hostのLAN IP)
export OLLAMA_BASE_URL='http://192.168.x.x:11434/v1'
# 未指定なら hostname -I から自動推測
./scripts/bootstrap.sh
```
完了するとアクセスURLが表示される。

### 4. ブラウザでアクセス
- 自分のPC: `http://localhost:2718/`
- LAN他PC: `http://<このマシンのLAN_IP>:2718/`

marimo UI を開いたら:
1. **Settings → Lab → "agents" を有効化**(初回のみ。ブラウザ側設定)
2. 左サイドバーのエージェントアイコン
3. **"Codex" を選択**(Claude ではない) → そのまま会話開始
4. ブラウザは `ws://<同じホスト>:3021/message` に自動接続(Codex用 port)

### 5. 後片付け
```bash
./scripts/teardown.sh
```

### 警告抑制(model_catalog_json)について

Codex CLI は未知のモデルに対して「**Model metadata for X not found. Defaulting to fallback metadata; this can degrade performance and cause issues.**」警告を出す(Ollama+Codex 既知問題、[ollama/ollama#14752](https://github.com/ollama/ollama/issues/14752))。

Ollama PR #15795 が `ollama launch codex` 経由で `~/.codex/model.json` を生成して Codex に渡す方法を提供しているが、**本構成は Pod 内 codex-acp が host の Ollama に直接接続する形のため、launcher 経由の修正の恩恵を受けられない**。

そのため、本リポジトリでは **同等の model.json を手動組み立てして ConfigMap (`codex-catalog`) で Pod に注入**する形で警告を抑制している:

- `manifests/step1/deployment.yaml` で `codex-catalog` ConfigMap を `/etc/codex-catalog/model.json` に readonly mount
- `entrypoint.sh` が `~/.codex/config.toml` に `model_catalog_json = "/etc/codex-catalog/model.json"` を書く
- ConfigMap の中身は Ollama `/api/show` の応答(context_length, capabilities 等)を元に、Codex の `buildCodexModelEntry` ([cmd/launch/codex.go](https://github.com/ollama/ollama/blob/main/cmd/launch/codex.go))と同じフィールド構造で組み立てた JSON

**モデルを変更する場合**(例: gemma → qwen):
1. `docker exec ollama curl localhost:11434/api/show -d '{"name":"<新モデル>"}'` で context_length と capabilities を確認
2. `kubectl create configmap codex-catalog --from-file=model.json=<新catalog> --dry-run=client -o yaml | kubectl apply -f -` で更新
3. `kubectl rollout restart deploy/marimo` で反映

---

# Step 4: 複数人並走 PoC

1台のサーバー上で `nb1` / `nb2` 2つの marimo 環境を独立に動かし、`nb1.<LAN_IP>.nip.io` / `nb2.<LAN_IP>.nip.io` で別々にアクセスできる構成。

## 構成図(Step 4)

```
ブラウザ
  ① http://nb1.<IP>.nip.io/              → nginx:80   → marimo-nb1 (marimo)
  ② ws://nb1.<IP>.nip.io:3017/message    → nginx:3017 → marimo-nb1 (acp)
  ① http://nb2.<IP>.nip.io/              → nginx:80   → marimo-nb2 (marimo)
  ② ws://nb2.<IP>.nip.io:3017/message    → nginx:3017 → marimo-nb2 (acp)
                       ▼
┌─ Service nginx-gateway (NodePort) ────────────────────┐
│  hostPort 80   → nodePort 30080  → nginx:80           │
│  hostPort 3017 → nodePort 30317  → nginx:3017         │
└───────────────────────────────────────────────────────┘
                       │
       Hostヘッダ振り分け (server_name 正規表現)
        ┌──────┴──────┐
        ▼             ▼
┌─ Pod nb1 ───┐  ┌─ Pod nb2 ───┐
│ marimo:2718 │  │ marimo:2718 │
│ acp:3017    │  │ acp:3017    │
│ PVC nb1     │  │ PVC nb2     │
└─────────────┘  └─────────────┘
```

> **なぜ nip.io?** `nb1.192.168.64.32.nip.io` のような名前を公開ワイルドカードDNSが
> 自動で `192.168.64.32`(=家のLAN内のサーバーIP)に解決してくれる。各PCに `/etc/hosts`
> やDNSサーバーの設定を一切せず、家庭内Bonjour (`*.local`) とも完全に独立。
> プライベートIPなのでDNS名は世界中から見えても通信はLAN内で完結する。

## クイックスタート(Step 4)

```bash
./scripts/install-tools.sh                # 初回のみ
claude setup-token                        # 手元端末で。出力トークンをコピー
export CLAUDE_CODE_OAUTH_TOKEN='<貼り付け>'
./scripts/bootstrap-step4.sh              # クラスタ作成〜デプロイ〜起動待ち
```

> ⚠️ Claude Code チャットの shell モード(`!` プレフィックス)では履歴に env 値が
> 残るので、トークンは普通のターミナルで実行すること。

> ⚠️ Step 1 が既にデプロイ済みの状態で Step 4 を実行すると、Service の NodePort
> (30317)が競合して失敗する。`bootstrap-step4.sh` は事前検知して停止し、
> `./scripts/teardown.sh` での切り替えを促す。Step 同士の切り替えは
> 常にクラスタ再作成(teardown → bootstrap)で行うのが安全。

完了すると以下のURLが案内される(同じLAN上の任意のPCから):

- `http://nb1.<LAN_IP>.nip.io/`
- `http://nb2.<LAN_IP>.nip.io/`

各々で **Settings → Lab → "agents" 有効化** → エージェントパネルから Claude を選択。
ACP WS は同じホスト名の `:3017` に自動接続される(nginxがHostヘッダで該当Podへ流す)。

## ディレクトリ構成

| パス | 役割 |
|---|---|
| `kind/cluster-step1.yaml` | Step 1 用 kind 設定。2718/3017 を LAN に bind(:80 は触らない) |
| `kind/cluster-step4.yaml` | Step 4 用 kind 設定。80/3017 を LAN に bind(:2718 は使わない) |
| `images/marimo/Dockerfile` | marimo公式イメージ + `marimo[mcp]` extras。`--mcp` 常時ON、`--mcp-allow-remote` は env `MARIMO_ALLOW_REMOTE_MCP=1` opt-in |
| `images/acp-agent/Dockerfile` | ACPサイドカーイメージ(node + stdio-to-ws + claude-code-acp + Claude Code SDK) |
| `images/acp-agent/entrypoint.sh` | 起動時にmarimoのMCPサーバーをClaude Codeに自動登録 |
| `manifests/namespace.yaml` | 専用 namespace `marimo`(Step1/4共通) |
| `manifests/secret.example.yaml` | Secret形式参考(実体はbootstrapで生成、Step1/4共通) |
| `manifests/step1/{pvc,deployment,service}.yaml` | Step 1: 単一Pod + NodePort(2718/3017) |
| `manifests/step4/notebook-nb{1,2}.yaml` | Step 4: テナント別 PVC+Deployment+Service(ClusterIP) |
| `manifests/step4/nginx-{configmap,deployment}.yaml` | Step 4: 前段 nginx と Hostヘッダ振り分け設定 |
| `scripts/bootstrap.sh` | Step 1 用 |
| `scripts/bootstrap-step4.sh` | Step 4 用 |
| `scripts/install-tools.sh` | kind/kubectl の sudo なしインストール |
| `scripts/teardown.sh` | クラスタ削除(PVC含む。Step1/4共通) |
| `docs/SETUP.md` | 詳細手順とトラブルシューティング |

## エージェントが使えるツール(Step 1/4 共通)

ACPで接続したClaude Codeは、以下を使ってノートブックを操作・観察できる:

**ACPプロトコル由来(常時利用可)**
- `Read` / `Edit` / `Write` — marimoノートブック(.py)の読み書き

**marimoのMCPサーバー由来**(本構成では `--mcp` 有効化済みで自動登録。Pod内で `mcp__marimo__*` として見える)
- `get_active_notebooks` — 開いているノートブック一覧
- `get_lightweight_cell_map` — 全セルの概要
- `get_cell_runtime_data` — セルのコード、エラー、変数情報
- `get_cell_outputs` — セルの出力(HTML、チャート等)
- `get_cell_dependency_graph` — セル依存関係グラフ
- `get_notebook_errors` — 失敗セルとフルトレースバック
- `get_tables_and_variables` — データフレームや変数の情報
- `get_database_tables` — DBスキーマ
- `get_marimo_rules` — marimo向けAIガイドライン
- `lint_notebook` — ノートブックのLint実行
- プロンプト: `active_notebooks`, `errors_summary`

> marimoのMCPサーバーは `http://localhost:2718/mcp/server`(HTTP)で公開され、同Pod内のACPサイドカーが起動時に `claude mcp add` で自動登録する。クライアント側は何も触らなくてよい。
> 公式ドキュメント(`docs/guides/editor_features/mcp.md`)に載っていないツールも含まれているので、最新の一覧はPod内で `claude mcp list` を叩くか、marimo UI のエージェントパネルで Claude に直接聞くのが確実。Deployment名は Step1なら `marimo`、Step4なら `marimo-nb1` / `marimo-nb2`(`--context` を明示することで current context が別クラスタを指していても安全):
> ```bash
> # Step 1
> kubectl --context kind-marimo -n marimo exec deploy/marimo     -c acp-agent -- claude mcp list
> # Step 4
> kubectl --context kind-marimo -n marimo exec deploy/marimo-nb1 -c acp-agent -- claude mcp list
> ```

## 意図的に妥協している点(両 Step 共通)

- **marimoの認証**: `--no-token`(公式イメージのデフォルト)で動かしているため、
  LAN内の誰でもUIを開けばノートブックを編集できる。Step 4 でも nginx 側に
  認証は載せていない(本物の運用に進む時に Basic Auth / OIDC 等を追加)。
- **TLS なし(平文HTTP/WS)**: LAN/VPN前提。
- **MCPエンドポイント `/mcp/server` も認証なしで LAN 公開**:
  `--no-token` 下では `RequiresEditMiddleware` も素通り。LAN内なら誰でも
  ノートブックの読み書きツールを叩ける。なお `--mcp-allow-remote`
  (DNS rebinding 保護無効化フラグ)は **デフォルトOFF**(env opt-in)。
- **Step 4: nip.io 公開DNS依存**: 名前は世界中から見えるが、解決先がLANの
  プライベートIPなので外部から到達はできない。気になる場合は家庭内 dnsmasq
  またはルーターの静的DNS機能を使う方式に切り替え可能(Service宛先は不変)。

## 関連 Issue / 参考
- marimo Agents 公式: https://docs.marimo.io/guides/editor_features/agents/
- 3017 ハードコード関連: marimo-team/marimo#8531(プロキシ提案・未実装), #6611(リモート接続不可)
- Claude Code Headless 認証: https://code.claude.com/docs/en/authentication
- nip.io: https://nip.io/
