# 詳細セットアップとトラブルシューティング

## 前提環境の確認

| 項目 | 確認コマンド | 期待値 |
|---|---|---|
| Linux | `uname -a` | `Linux` |
| Docker | `docker ps` | エラーなく動く(`docker` グループ所属) |
| Claude Code CLI | `claude --version` | `2.x` |
| Claudeサブスク | `claude /login` 済み | Pro / Max / Team / Enterprise |

## 手順詳細

### 1. ツール導入
`scripts/install-tools.sh` は `~/.local/bin` に kind と kubectl を置く。`~/.local/bin` が PATH にない場合は `.bashrc` 等で:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### 2. Claude OAuth トークン取得

> 公式ドキュメント: https://code.claude.com/docs/en/authentication#generate-a-long-lived-token

```bash
claude setup-token
```

**フローと注意点(よくあるハマり):**

1. ブラウザが開き、OAuth認可フローが始まる
2. ブラウザが「**認可コード**」を表示する場面が出る(リダイレクト失敗時など)
3. **その認可コードは `claude setup-token` が動いているターミナルに貼り戻す**側のもの(WSL/SSH/コンテナだとリダイレクトが失敗するため手貼りになる)
4. ターミナルに貼り戻すと、`claude setup-token` がOAuthトークン交換を行い、**改めて長いトークン文字列をターミナルに出力**する
5. **このステップ4で出力されたトークンこそが `CLAUDE_CODE_OAUTH_TOKEN` に入れる値**(2の認可コードではない)

> ⚠️ **間違いやすい**: 2の認可コードを `CLAUDE_CODE_OAUTH_TOKEN` に入れて bootstrap すると、API から `401 Invalid bearer token` で蹴られる。長さの目安として `claude setup-token` 出力のトークンは `sk-ant-oat-...` 形式の長い文字列(120字程度)で、2の認可コードよりはるかに長い。

その他の注意:
- このトークンは**どこにも保存されない**ので、ターミナル出力から必ずコピーする
- 有効期限は **1年**
- `inference only`(=対話/エージェント利用に限定)。Pro/Max/Team/Enterprise サブスクに紐づく

> ⚠️ **2026年6月15日以降の注意**: サブスクプランでの Agent SDK / `claude -p` 利用は対話利用とは別枠の月次 Agent SDK クレジットから消費される(公式ドキュメント明記)。`@zed-industries/claude-code-acp` は Agent SDK 経由のため影響を受ける。

### 3. デプロイ実行

```bash
export CLAUDE_CODE_OAUTH_TOKEN='paste-here'
./scripts/bootstrap.sh
```

スクリプトは以下を順に実行:
1. kindクラスタ `marimo` の作成(存在しなければ)
2. ACPサイドカーイメージ `marimo-envs/acp-agent:0.1.0` のビルド
3. `kind load docker-image` でクラスタ内に配置
4. namespace / PVC / Secret / Deployment / Service を順に apply
5. `kubectl rollout status` で起動完了を待機

### 4. 動作確認

```bash
# Pod が Running か
kubectl -n marimo get pods

# marimo のログ(Listening on 0.0.0.0:2718 が出る)
kubectl -n marimo logs deploy/marimo -c marimo

# ACPサイドカーのログ(stdio-to-ws が listen している様子)
kubectl -n marimo logs deploy/marimo -c acp-agent

# ホスト側でポートが開いているか
ss -tlnp | grep -E ':2718|:3017'  # LISTEN 0.0.0.0:2718, 0.0.0.0:3017 が見えるはず
```

ブラウザで `http://localhost:2718/` を開く。Lab フラグを有効化してエージェントパネルを開き、Claude を選択。WSが繋がると「接続OK」状態になり、メッセージが送れる。

## トラブルシューティング

### marimo UI は開けるがエージェントが繋がらない

ブラウザの開発者ツール → Network → WS タブで `ws://...:3017/message` のフレームを見る。
- **404 や接続失敗**: ACPサイドカーが落ちているか、ポート転送がない。`kubectl -n marimo logs deploy/marimo -c acp-agent` と `ss -tlnp | grep 3017` を確認。
- **`401 Invalid bearer token`**: トークンが間違っているか期限切れ。最頻ケースは `claude setup-token` のフローで「**ブラウザに出る認可コード**」を `CLAUDE_CODE_OAUTH_TOKEN` に入れてしまうミス。手順2の「フローと注意点」を再読。正しいトークンを取り直して bootstrap.sh を再実行すれば Secret の更新 + Pod の rollout restart まで自動で行われる:
  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN='<正しい長いトークン>'
  ./scripts/bootstrap.sh
  ```

### LAN の他PC から繋がらない
- ホスト側 firewall(`ufw` / `firewalld` / `iptables`)で 2718, 3017 が許可されているか確認
- kind は `listenAddress: "0.0.0.0"` 指定済み(`kind/cluster.yaml`)。`ss -tlnp` で `0.0.0.0:2718` と表示されていればOK、`127.0.0.1:2718` なら kind の再作成が必要

### Pod が CrashLoopBackOff になる
```bash
kubectl -n marimo describe pod -l app=marimo
kubectl -n marimo logs -p deploy/marimo -c <container>
```
- 共有Volumeの権限が原因なら `securityContext.fsGroup: 1000`(deployment.yaml)が効いているか確認
- ACPサイドカーで `claude-code-acp` が `CLAUDE_CODE_OAUTH_TOKEN` を読めていない可能性 → Secret の中身を確認

### ノートブックが保存されない
PVC `marimo-workspace` が Bind されているか:
```bash
kubectl -n marimo get pvc
```
`Pending` なら kind の `local-path-provisioner` が動いていない。`kubectl get pods -n local-path-storage` を確認。

## marimo MCP サーバーの動作確認

本構成では marimo の `--mcp` フラグを有効化し、ACPサイドカー起動時に Claude Code 側へ自動登録している。動作確認は次の通り:

```bash
# marimo起動ログに "Experimental MCP server configuration" 行があるか
kubectl -n marimo logs deploy/marimo -c marimo | grep -iE 'mcp|experimental'

# ACPサイドカー側で MCP 設定が登録されているか
kubectl -n marimo logs deploy/marimo -c acp-agent | grep -iE 'mcp|entrypoint'

# Claude Code 設定上の MCP 一覧(health check付き)
kubectl -n marimo exec deploy/marimo -c acp-agent -- claude mcp list
# 期待: "marimo: http://localhost:2718/mcp/server (HTTP) - ✓ Connected"
```

> 補足: acp-agent イメージには curl が入っていないので、エンドポイントを HTTP で直接叩いて確認したい場合は `claude mcp list` のhealth checkに任せる。

marimo UI のエージェントパネルで、Claude に「現在のMCPツール一覧を教えて」のように聞いた際、`mcp__marimo__get_notebook_errors` などの `mcp__marimo__*` ツールが現れていれば成功。なお実際に提供されるツールは `mcp.md` 公式記載より多い(`lint_notebook`, `get_cell_outputs`, `get_cell_dependency_graph` 等)。

## 今後のステップ(プロジェクトロードマップ)

| Step | 内容 | 主な変更点 |
|---|---|---|
| 1 (現在) | 1人での試用 | 3017固定のまま、本構成のまま |
| 2 | 情シスにワイルドカードDNS `*.notebook.local → サーバーIP` 申請 | k8s側変更なし |
| 3 | 上司含む2–3人デモ | 同時利用しない約束で運用、Lab フラグはユーザーごとに有効化 |
| 4 | 複数ユーザー並列 + nginx Host振り分け(A-1方式) | Deployment をユーザー数分テンプレート化、前段に nginx 追加 |
| 5 | 本番k8s(EKS/GKE/AKS等)へ移行 | LoadBalancer / Ingress / TLS など本番要素を導入 |

**ステップ4 で複数Pod並列に移行する際の見立て:**
- 同じ Deployment テンプレートをユーザー別に複製(`marimo-alice`, `marimo-bob` ...)
- 前段に nginx(または Traefik 等)を置き、`alice.notebook.local` → `marimo-alice` Service、`bob.notebook.local` → `marimo-bob` Service へ Host ヘッダで振り分け
- ブラウザは `wss://alice.notebook.local:3017/message` を叩く → 同 nginx の 3017 SNI/Host振り分けが必要(WSはL4寄りなので Stream モジュール or 別 listener)
- marimo フォーク&パッチは採用しない方針(運用工数 > DNS整備の工数)
