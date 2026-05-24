# marimo + Claude Code on Kubernetes

marimo の **エージェント機能(Claude Code)** を、Kubernetes (kind) 上で動かす分析環境。

2 つの構成を用意している:

| Step | 想定 | アクセス | マニフェスト | bootstrap |
|---|---|---|---|---|
| **Step 1** | 1人で試用 | `http://<LAN_IP>:2718/` | `manifests/step1/` | `scripts/bootstrap.sh` |
| **Step 4 (PoC)** | 同一サーバーで複数人並走 | `http://nb1.<LAN_IP>.nip.io/`, `http://nb2.<LAN_IP>.nip.io/` | `manifests/step4/` | `scripts/bootstrap-step4.sh` |

## 構成の選び方

- **1人で軽く触る** → Step 1。Pod 1個、ポート2718/3017を直接公開
- **複数人(2人〜)に同時アクセスさせたい** → Step 4。nginx 前段で Hostヘッダ振り分け + nip.io ワイルドカードDNS
- 一気に最終形(本物のk8s + Ingress + TLS)に飛ぶ予定があるなら、本リポジトリは PoC 用と割り切ってロードマップは [docs/SETUP.md](docs/SETUP.md) を参照

## 設計の核心(両 Step 共通)

marimo のブラウザJSは ACP の WebSocket URL を
`ws://${window.location.hostname}:3017/message` でハードコードしている
(`frontend/src/components/chat/acp/state.ts` の `getAgentWebSocketUrl`)。

**そのため marimo (HTTP 2718 or 80) と ACP (3017) を「同じホスト名/IP」に揃えて公開しないと繋がらない。** これが本リポジトリ全体の制約。

- Step 1: 同一 LAN_IP 上に :2718 と :3017 を NodePort で並べて解決
- Step 4: nginx が :80 と :3017 の両方を Listen し、Hostヘッダで Pod を振り分け(`nb1.<IP>.nip.io` / `nb2.<IP>.nip.io` のように同じ名前でアクセス)

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

### 2. Claude OAuth トークン取得
ブラウザのある手元の端末で:
```bash
claude setup-token
```
表示された1年有効のトークンをコピーする。

### 3. デプロイ
```bash
export CLAUDE_CODE_OAUTH_TOKEN='<貼り付け>'
./scripts/bootstrap.sh
```
完了するとアクセスURLが表示される。

### 4. ブラウザでアクセス
- 自分のPC: `http://localhost:2718/`
- LAN他PC: `http://<このマシンのLAN_IP>:2718/`

marimo UI を開いたら:
1. **Settings → Lab → "agents" を有効化**(初回のみ。ブラウザ側設定)
2. 左サイドバーのエージェントアイコン
3. "Claude" を選択 → そのまま会話開始

### 5. 後片付け
```bash
./scripts/teardown.sh
```

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
| `kind/cluster.yaml` | kindクラスタ設定。`extraPortMappings` で 80 / 2718 / 3017 を LAN に出す |
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
> 公式ドキュメント(`docs/guides/editor_features/mcp.md`)に載っていないツールも含まれているので、最新の一覧はPod内で `claude mcp list` を叩くか、marimo UI のエージェントパネルで Claude に直接聞くのが確実。Deployment名は Step1なら `marimo`、Step4なら `marimo-nb1` / `marimo-nb2`:
> ```bash
> # Step 1
> kubectl -n marimo exec deploy/marimo     -c acp-agent -- claude mcp list
> # Step 4
> kubectl -n marimo exec deploy/marimo-nb1 -c acp-agent -- claude mcp list
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
