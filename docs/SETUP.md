# 詳細セットアップとトラブルシューティング

> **Step 1(1人での試用)と Step 4(複数人並走PoC)の両方を扱う。** 共通の前提・トークン取得・MCP動作確認は両方に効く。bootstrapスクリプトと一部マニフェストだけが Step ごとに分かれる。

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

> ⚠️ トークンは Claude Code チャットの `!` プレフィックス(shellモード)では
> 履歴に env 値が残るので、**普通のターミナル**で `export` または1回のコマンドの
> 前置きとして実行すること。

### 3-A. デプロイ実行(Step 1: 1人)

```bash
export CLAUDE_CODE_OAUTH_TOKEN='paste-here'
./scripts/bootstrap.sh
```

スクリプトは以下を順に実行:
1. kindクラスタ `marimo` の作成(存在しなければ)
2. marimo拡張イメージと ACPサイドカーイメージのビルド
3. `kind load docker-image` でクラスタ内に配置
4. namespace / PVC / Secret / Deployment / Service を順に apply(`manifests/step1/`)
5. `kubectl rollout restart`(Secret更新を新Podへ反映) + `kubectl rollout status` で起動完了を待機

### 3-B. デプロイ実行(Step 4: 複数人 PoC)

```bash
export CLAUDE_CODE_OAUTH_TOKEN='paste-here'
./scripts/bootstrap-step4.sh
```

> ⚠️ Step 1 と Step 4 は同じクラスタ名 `marimo` と同じ NodePort `30317` を使うため、
> 既に Step 1 が apply 済みの状態で Step 4 を実行すると Service 作成が NodePort 競合で
> 失敗する。`bootstrap-step4.sh` は事前にこれを検知して停止し、`teardown.sh` を促す。
> Step 切り替え時はクラスタ削除 → bootstrap の流れに統一するのが安全。

Step 1 との違い:
- kindクラスタの `extraPortMappings` に **`hostPort: 80`** が必要(`kind/cluster.yaml` で対応済)
- `manifests/step4/` 配下を apply:
  - `nginx-configmap.yaml` + `nginx-deployment.yaml`(前段ゲートウェイ)
  - `notebook-nb1.yaml` + `notebook-nb2.yaml`(2テナント分の PVC/Deployment/Service)
- Secret `claude-code-token` は両テナントで共有
- 完了後の出力に `http://nb1.<LAN_IP>.nip.io/` と `http://nb2.<LAN_IP>.nip.io/` が案内される

### 4-A. 動作確認(Step 1)

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

### 4-B. 動作確認(Step 4)

```bash
# 3つのDeploymentが全部Ready
kubectl -n marimo get pods
# 期待: nginx-gateway-..., marimo-nb1-..., marimo-nb2-... が全部 Running 2/2 or 1/1

# nginx 設定がロードされたか
kubectl -n marimo logs deploy/nginx-gateway | tail -5

# 各テナント Pod の marimo / acp-agent ログ
kubectl -n marimo logs deploy/marimo-nb1 -c marimo
kubectl -n marimo logs deploy/marimo-nb2 -c acp-agent

# ホスト側ポート(80 と 3017 が両方 LISTEN しているはず)
ss -tlnp | grep -E ':80 |:3017'

# nip.io 解決確認
getent hosts "nb1.$(hostname -I | awk '{print $1}').nip.io"
# 期待: <LAN_IP> nb1.<LAN_IP>.nip.io

# nginx 経由の HTTP/WS 振り分け確認(同一マシンから簡易テスト)
LAN_IP=$(hostname -I | awk '{print $1}')
curl -sS -o /dev/null -w '%{http_code}\n' "http://nb1.${LAN_IP}.nip.io/"
curl -sS -o /dev/null -w '%{http_code}\n' "http://nb2.${LAN_IP}.nip.io/"
# 期待: 両方とも 200(または marimoのトップへのリダイレクト系)
```

ブラウザで `http://nb1.<LAN_IP>.nip.io/` を開く。エージェント有効化後、Networkタブで `ws://nb1.<LAN_IP>.nip.io:3017/message` が確立されることを確認。同じ手順で nb2 も別の独立した環境として開ける。

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
- ホスト側 firewall(`ufw` / `firewalld` / `iptables`)で 該当ポート(Step1: 2718/3017, Step4: 80/3017)が許可されているか確認
- kind は `listenAddress: "0.0.0.0"` 指定済み(`kind/cluster.yaml`)。`ss -tlnp` で `0.0.0.0:<port>` と表示されていればOK、`127.0.0.1:...` なら kind の再作成が必要

### Step 4: `nb1.*.nip.io` が解決されない
- 公開DNSが落ちていることはまずないので、自分のPCのDNSサーバー指定を確認
- 試しに `nslookup nb1.<LAN_IP>.nip.io 1.1.1.1` で別のDNSに直接問い合わせて返ってくるか
- 名前は世界中から見える(IP埋め込み型)が、解決先はLANのプライベートIPなので**外部から到達はできない**

### Step 4: ブラウザは `nbN.*.nip.io/` 開けるがエージェントが繋がらない
- ブラウザの開発者ツール → Network → WS で `wss?://nbN.<LAN_IP>.nip.io:3017/message` を見る
- 404: nginx の :3017 リスナーで Hostヘッダがマッチしていない可能性 → `kubectl -n marimo logs deploy/nginx-gateway` で `404` ログを確認、`server_name` の正規表現が `nbN\..+\.nip\.io` の形にマッチしているか
- 接続失敗: nginx Pod が落ちているか、ホスト側 :3017 が開いていない → `kubectl -n marimo get pods`, `ss -tlnp | grep 3017`

### Pod が CrashLoopBackOff になる
```bash
kubectl -n marimo describe pod -l app=marimo
kubectl -n marimo logs -p deploy/<marimo / marimo-nb1 / marimo-nb2> -c <container>
```
- 共有Volumeの権限が原因なら `securityContext.fsGroup: 1000` が効いているか確認
- ACPサイドカーで `claude-code-acp` が `CLAUDE_CODE_OAUTH_TOKEN` を読めていない可能性 → Secret の中身を確認

### ノートブックが保存されない
PVC が Bind されているか:
```bash
kubectl -n marimo get pvc
# Step1: marimo-workspace
# Step4: marimo-workspace-nb1, marimo-workspace-nb2
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

### ⚠️ MCP のセキュリティ前提(Step 1 / Step 4 共通)

本リポジトリでは以下を **意図的に許容している**:

- **MCPは無認証で外部到達可能**: marimo は `--no-token` で動いているため、`/mcp/server`
  エンドポイントも `RequiresEditMiddleware` を素通りする。Step 1 なら
  `http://<LAN_IP>:2718/mcp/server`、Step 4 なら `http://nbN.<LAN_IP>.nip.io/mcp/server`
  に到達できる相手なら、`get_cell_runtime_data` 等の読み書きツールを叩ける。
- **`--mcp-allow-remote` は デフォルトOFF**(両 Step 共通の現状設定): DNS rebinding 保護
  (= 許可ホストヘッダ以外を marimo が弾く機能)を無効化するフラグ。
  - **Step 1** はACPサイドカーが Pod 内 `localhost:2718` で繋ぐので Host=localhost
    となり保護を素通りできる(=フラグ不要、デフォルトOFFで動く)
  - **Step 4** は ACPサイドカーは同じく Pod 内 `localhost:3017` 経由で nginx を通らないが、
    **ブラウザから直接 `http://nbN.<LAN_IP>.nip.io/mcp/server` を叩く動線が新たに増える**。
    nginx は `proxy_set_header Host $host;` で `Host: nbN.<LAN_IP>.nip.io` を marimo に
    透過するため、現状の `--mcp-allow-remote` OFF では **ブラウザから直接 MCP を叩く動線
    だけは DNS rebinding 保護で 421 等になる**(ACPエージェント経由は引き続き動く)。
    ブラウザから直接 MCP エンドポイントを叩く必要がある運用に進むなら、env
    `MARIMO_ALLOW_REMOTE_MCP=1` で opt-in するか、nginx 側で `/mcp/server` への
    proxy_pass だけ `proxy_set_header Host "localhost:2718";` のように書き換える方式
    (より絞った許可)を検討。

**許容する根拠と緩和策:**
- 用途は信頼ネットワーク(家庭内LAN / 社内LAN / VPN)内のPoC運用に限定
- ホスト側ファイアウォール(`ufw` / `firewalld`)で 該当ポートを絞ること推奨
- 本番化(Step 5)では nginx / Ingress に Basic Auth or OIDC を載せる
- TLSはStep 5(LB/Ingress導入時)で考慮

不特定多数からアクセスされる環境では、本構成を絶対に使わないこと。

## 今後のステップ(プロジェクトロードマップ)

| Step | 内容 | 状態 |
|---|---|---|
| 1 | 1人での試用(3017直接公開) | ✅ 完了。`scripts/bootstrap.sh` で再現 |
| 2 | 社内ネットワークでのワイルドカードDNS手配 | (家庭環境では nip.io で代替済み。会社では情シスに相談予定) |
| 3 | 上司含む2–3人デモ | 未着手 |
| 4 | 複数ユーザー並列 + nginx Host振り分け(PoC) | ✅ 完了。`scripts/bootstrap-step4.sh` で再現。`nb1` / `nb2` の2テナントで動作確認済み |
| 5 | 本番k8s(EKS/GKE/AKS等)へ移行 | 未着手。LoadBalancer / Ingress / TLS / 認証(Basic / OIDC) / 動的テナント発行 |

**Step 4 → Step 5 へ拡張する際の見立て:**
- `manifests/step4/notebook-nbN.yaml` をテンプレート化(Kustomize / Helm)してユーザー数を可変に
- nginx の Hostヘッダ振り分けを Ingress(Traefik / nginx-ingress)に置き換え
- 認証は Ingress 側で oauth2-proxy 等を挟む
- TLS は cert-manager で社内CAなり Let's Encrypt なり
- marimo フォーク&パッチは採用しない方針(運用工数 > DNS整備&Ingress整備の工数)
- 本家 `marimo-team/marimo#8531`(ACP WSをmarimoバックエンド経由でプロキシ)が
  実装されたら 3017 露出問題が消えるので Step 5 の Ingress 1ポート集約に乗せ替え
