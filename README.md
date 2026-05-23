# marimo + Claude Code on Kubernetes

marimo の **エージェント機能(Claude Code)** を、Kubernetes (kind) 上で動かす分析環境。

現在 **Step 1: 1人での試用** フェーズ。1Pod内に marimo と ACPサイドカーを同居させ、ローカルクラスタの LAN ポート (2718, 3017) を社内ネットワークに公開する最小構成。

## 構成図

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

**重要(設計の核心):** marimo のブラウザJSは ACP の WebSocket URL を
`ws://${window.location.hostname}:3017/message` でハードコードしている
(`frontend/src/components/chat/acp/state.ts` の `getAgentWebSocketUrl`)。
そのため marimo (2718) と ACP (3017) を **同じホスト名/IP に揃えて** 公開する
必要がある。

## クイックスタート

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

## ディレクトリ構成

| パス | 役割 |
|---|---|
| `kind/cluster.yaml` | kindクラスタ設定。`extraPortMappings` で 2718/3017 を LAN に出す |
| `images/marimo/Dockerfile` | marimo公式イメージ + `marimo[mcp]` extras + `--mcp --mcp-allow-remote` 起動 |
| `images/acp-agent/Dockerfile` | ACPサイドカーイメージ(node + stdio-to-ws + claude-code-acp + Claude Code SDK) |
| `images/acp-agent/entrypoint.sh` | 起動時にmarimoのMCPサーバーをClaude Codeに自動登録 |
| `manifests/namespace.yaml` | 専用 namespace `marimo` |
| `manifests/pvc.yaml` | ノートブック永続化用 PVC(5Gi, RWO) |
| `manifests/deployment.yaml` | marimo + acp-agent の2コンテナPod |
| `manifests/service.yaml` | NodePort Service(2718 → 30718, 3017 → 30317) |
| `manifests/secret.example.yaml` | Secretの形式参考(実体は bootstrap.sh で生成) |
| `scripts/bootstrap.sh` | クラスタ作成 → ビルド → load → apply の一連 |
| `scripts/install-tools.sh` | kind/kubectl の sudo なしインストール |
| `scripts/teardown.sh` | クラスタ削除(PVC含む) |
| `docs/SETUP.md` | 詳細手順とトラブルシューティング |

## エージェントが使えるツール

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
> 公式ドキュメント(`docs/guides/editor_features/mcp.md`)に載っていないツールも含まれているので、最新の一覧はPod内で `kubectl -n marimo exec deploy/marimo -c acp-agent -- claude mcp list` または marimo UI のエージェントパネルで Claude に直接聞くのが確実。

## Step 1 で意図的に妥協している点

- **marimoの認証**: `--no-token`(公式イメージのデフォルト)で動かしているため、
  LAN 内の誰でも UI を開けばノートブックを編集できる。Step 3 で複数人デモする際は
  「同時利用しない約束」運用、Step 4 以降で nginx 側に Basic Auth 等を追加予定。
- **TLS なし(平文HTTP/WS)**: LAN/VPN前提。
- **3017 を直接 LAN に露出**: 本来は Ingress に集約したいが、marimo フロントエンドが
  ポートをハードコードしているため Step 1 では直接公開する。将来の対策は
  [docs/SETUP.md](docs/SETUP.md) の「今後のステップ」を参照。

## 関連 Issue / 参考
- marimo Agents 公式: https://docs.marimo.io/guides/editor_features/agents/
- 3017 ハードコード関連: marimo-team/marimo#8531(プロキシ提案・未実装), #6611(リモート接続不可)
- Claude Code Headless 認証: https://code.claude.com/docs/en/authentication
