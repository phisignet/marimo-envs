# 詳細セットアップとトラブルシューティング

> **Step 1(1人での試用)と Step 4(複数人並走PoC)の両方を扱う。** 共通の前提・トークン取得・MCP動作確認は両方に効く。本書は **`--agent claude`** 前提で書かれている(OAuthトークン取得など Claude 固有手順を含むため)。
>
> **Codex + Ollama 構成は README の「統合 CLI」セクションを参照**(`./scripts/bootstrap.sh --step <S> --agent codex`)。
>
> **Copilot CLI 構成**は `--agent copilot` で起動可能。手順は本書 3-A / 3-B の `CLAUDE_CODE_OAUTH_TOKEN` を `COPILOT_GITHUB_TOKEN`(GitHub PAT)に読み替え、UI 上のエージェント選択肢は「**Cursor**」(中身は Copilot CLI)を選ぶ。設計の経緯は [copilot-agent-design.md](copilot-agent-design.md) を参照。

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

### 3-0. `.env` でトークンを渡す(任意・推奨)

毎回 `export` する代わりに、リポジトリ直下の `.env` に書いておけば
`bootstrap.sh` が起動時に自動読込する(`.env` は `.gitignore` 済み=コミットされない)。

```bash
cp .env.example .env
# .env を編集して使う agent のトークンを記入(例: COPILOT_GITHUB_TOKEN=github_pat_xxx)
./scripts/bootstrap.sh --step 1 --agent copilot   # export 不要
```

- 既に `export` 済みの環境変数があればそちらを優先(`.env` では上書きしない)。
- 値の囲みクォート(`"..."` / `'...'`)あり/なしどちらでも可。
- 記入できる変数の一覧と説明は [`.env.example`](../.env.example) を参照。

以降の 3-A / 3-B では `export ...` を例示するが、`.env` に書いた場合はその行は不要。

### 3-A. デプロイ実行(Step 1: 1人)

```bash
export CLAUDE_CODE_OAUTH_TOKEN='paste-here'
./scripts/bootstrap.sh --step 1 --agent claude
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
./scripts/bootstrap.sh --step 4 --agent claude
```

> ⚠️ Step 1 と Step 4 は同じクラスタ名 `marimo` と同じ NodePort `30080`(nginx-gateway)を
> 使うため、既に一方が apply 済みの状態でもう一方を実行すると Service 作成が NodePort 競合で
> 失敗する。`bootstrap.sh` は事前にこれを `check_nodeport_conflict` で検知して停止し、
> `teardown.sh` を促す。Step 切り替え時はクラスタ削除 → bootstrap の流れに統一するのが安全。

Step 1 との違い:
- `manifests/step4/` 配下を apply:
  - `nginx-configmap.yaml` + `nginx-deployment.yaml`(前段ゲートウェイ、path 振り分け)
  - `notebook-nb1.yaml` + `notebook-nb2.yaml`(2テナント分の PVC/Deployment/Service、各 `--base-url /nbN`)
- Secret `claude-code-token` は両テナントで共有
- 完了後の出力に `http://<LAN_IP>/nb1/?view-as=present` と `/nb2/?view-as=present` が案内される(nip.io 不要)

> 以降の `kubectl` コマンドは、current context が `kind-marimo`(本リポジトリの
> bootstrap が作るクラスタ)を指している前提で書いている。別クラスタを操作している
> 可能性があるなら、各コマンドに `--context kind-marimo` を付けるか、一度だけ
> `kubectl config use-context kind-marimo` を実行して固定すること。

### 4-A. 動作確認(Step 1)

```bash
# Pod が Running か
kubectl -n marimo get pods

# marimo のログ(Listening on 0.0.0.0:2718 が出る)
kubectl -n marimo logs deploy/marimo -c marimo

# ACPサイドカーのログ(stdio-to-ws が listen している様子)
kubectl -n marimo logs deploy/marimo -c acp-agent

# ホスト側で :80 が開いているか(Model Y: 公開は nginx 前段の :80 のみ。
# marimo/ACP は ClusterIP 内部で nginx 経由)。grep -E(ERE)では \b が使えないため
# ポート番号の後ろが「数字以外 or 行末」であることで締める([^0-9]|$)。
ss -tlnp | grep -E ':80([^0-9]|$)'  # 例: 0.0.0.0:80
```

ブラウザで `http://localhost/?view-as=present` を開く。app view(コード非表示)で
ノートブックが開けば OK(初回は `/workspace/notebook.py` が自動生成される)。Lab フラグを
有効化してエージェントパネルを開き、起動した agent を選択(claude→Claude / codex→Codex /
copilot→Cursor)。WSが繋がると「接続OK」状態になり、メッセージが送れる(WS は
`ws://localhost/acp/<id>` = :80 経由)。

エージェントに「セルを1つ追加して」等を依頼し、app view に即座に反映されれば
`--watch`/autorun か marimo-pair(code_mode)のどちらか(または両方)が機能している
(どちらの経路でも即時反映されるため、この確認だけでは両方の動作までは断定できない)。
起動後の使い方の詳細は [USAGE.md](USAGE.md) を参照。

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

# ホスト側 :80 が LISTEN しているか(Model Y: nginx 前段の :80 のみ公開)
ss -tlnp | grep -E ':80([^0-9]|$)'

# nginx 経由の path 振り分け確認(同一マシンから。nip.io 不要)
# /nbN/ は 302→/nbN/?view-as=present。最終的に 200 が返れば nginx→marimo-nbN が通っている。
curl -sS -L -o /dev/null -w '%{http_code}\n' "http://localhost/nb1/?view-as=present"
curl -sS -L -o /dev/null -w '%{http_code}\n' "http://localhost/nb2/?view-as=present"
# 期待: 両方とも 200
```

ブラウザで `http://<LAN_IP>/nb1/?view-as=present` を開く(nip.io 不要・生 IP でよい)。
エージェント有効化後、Networkタブで `ws://<LAN_IP>/nb1/acp/<id>/message` 相当が
**101 Switching Protocols** で確立されることを確認(平文 HTTP/WS なので `ws://`。TLS 化時は `wss://`)。
同じ手順で nb2 も別の独立した環境として開ける。

## トラブルシューティング

### Copilot で Autopilot モードにするとエラーになる

Copilot のチャットで **Autopilot をいきなり選ぶと** 失敗する:

```
{"details":"Permission service is unavailable for this session."} (code: -32603)
```

Copilot CLI の ACP モードで permission service が遅延初期化される(初回のツール権限
チェック時に生成)ことに起因する既知の挙動。Pod 設定の問題ではない。

**回避策(フラグ不要):**
1. まず **Agent モードで一度やり取り**する(ツール実行を1回走らせて permission
   service を初期化)。
2. その後 **Autopilot に切り替える**と成功する(Agent モードの承認はそのまま残る)。

全自動運用(human-in-the-loop なし)が必要なら、`images/copilot-acp/entrypoint.sh` の
`copilot` コマンドに `--yolo`(=`--allow-all`)を付けると起動時から autopilot 相当に
できるが、**全モードで承認が一切なくなる**(シェル・ファイル書込含む)ため、Step 4
複数人環境では危険。常用は非推奨。詳細は [USAGE.md](USAGE.md) §6。

### marimo UI は開けるがエージェントが繋がらない

ブラウザの開発者ツール → Network → WS タブで `ws://<host>/[nbN/]acp/<id>` のフレームを見る(Model Y: :80 経由・パス振り分け)。
- **404 や接続失敗**: ACPサイドカーが落ちているか nginx 設定不整合。`kubectl -n marimo logs deploy/<marimo|marimo-nbN> -c acp-agent` と `kubectl -n marimo logs deploy/nginx-gateway` を確認。
- **`401 Invalid bearer token`**: トークンが間違っているか期限切れ。最頻ケースは `claude setup-token` のフローで「**ブラウザに出る認可コード**」を `CLAUDE_CODE_OAUTH_TOKEN` に入れてしまうミス。手順2の「フローと注意点」を再読。正しいトークンを取り直して bootstrap.sh を再実行すれば Secret の更新 + Pod の rollout restart まで自動で行われる:
  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN='<正しい長いトークン>'
  ./scripts/bootstrap.sh --step <S> --agent claude   # 起動時と同じ --step を指定
  ```

### LAN の他PC から繋がらない
- ホスト側 firewall(`ufw` / `firewalld` / `iptables`)で **:80** が許可されているか確認
  (Model Y: 公開は nginx 前段の :80 のみ。ACP も :80 経由なので個別ポート開放は不要)。
- **kind 経由なら通常は透過**(Docker daemon が iptables ルールを動的挿入)。
- kind は `listenAddress: "0.0.0.0"` 指定済み。`ss -tlnp` で `0.0.0.0:80` と表示されていればOK、
  `127.0.0.1:80` なら kind の再作成が必要。

### Step 4: ブラウザは `/nbN/` 開けるがエージェントが繋がらない
- ブラウザの開発者ツール → Network → WS で `ws://<host>/nbN/acp/<id>` のフレームを見る
  (平文 HTTP/WS なので `ws://`。TLS 化時のみ `wss://`)。**101 Switching Protocols** なら確立。
- 404 / 426 など: nginx の `^~ /nbN/acp/` location が効いていない可能性 →
  `kubectl --context kind-marimo -n marimo logs deploy/nginx-gateway` でアクセスログを確認。
  WS Upgrade ヘッダ透過(`proxy_set_header Upgrade/Connection`)も確認。
- 接続失敗: nginx Pod が落ちている / ホスト :80 が開いていない →
  `kubectl --context kind-marimo -n marimo get pods`, `ss -tlnp | grep -E ':80([^0-9]|$)'`。
- サイドカーが死んでいないか: `kubectl -n marimo logs deploy/marimo-nb1 -c acp-agent`。

### Pod が CrashLoopBackOff になる

Deployment 名は Step1 なら `marimo`、Step4 なら `marimo-nb1` / `marimo-nb2`。

```bash
# Step 1
kubectl -n marimo describe pod -l app=marimo
kubectl -n marimo logs -p deploy/marimo -c marimo
kubectl -n marimo logs -p deploy/marimo -c acp-agent

# Step 4(nb1の例。nb2 も同様)
kubectl -n marimo logs -p deploy/marimo-nb1 -c marimo
kubectl -n marimo logs -p deploy/marimo-nb1 -c acp-agent
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
# Step 1 期待: "marimo: http://localhost:2718/mcp/server (HTTP) - ✓ Connected"
# Step 4(--base-url /nbN)期待: "http://localhost:2718/nbN/mcp/server - ✓ Connected"
#   (Deployment は marimo-nbN。MARIMO_MCP_URL でプレフィックス付き URL を注入済み)
```

> 補足: acp-agent イメージには curl が入っていないので、エンドポイントを HTTP で直接叩いて確認したい場合は `claude mcp list` のhealth checkに任せる。

marimo UI のエージェントパネルで、Claude に「現在のMCPツール一覧を教えて」のように聞いた際、`mcp__marimo__get_notebook_errors` などの `mcp__marimo__*` ツールが現れていれば成功。なお実際に提供されるツールは `mcp.md` 公式記載より多い(`lint_notebook`, `get_cell_outputs`, `get_cell_dependency_graph` 等)。

### ⚠️ MCP のセキュリティ前提(Step 1 / Step 4 共通)

本リポジトリでは以下を **意図的に許容している**:

- **MCPは無認証で到達可能**: marimo は `--no-token` のため `/mcp/server`(base-url 配下なら
  `/[nbN/]mcp/server`)も `RequiresEditMiddleware` を素通りする。:80 経由で到達できる相手は
  `get_cell_runtime_data` 等の読み書きツールを叩ける。
- **MCP の主動線は Pod 内 ACPエージェント**(`http://localhost:2718/[nbN/]mcp/server`)。
  Host=localhost で marimo に直接届く。`--mcp-allow-remote` はデフォルト OFF のまま。
- **ブラウザから :80 経由で MCP を直接叩く動線**は nginx が `Host: <LAN_IP>` を透過するため、
  現状 OFF では DNS rebinding 保護で弾かれうる(ACPエージェント経由は動く)。必要なら
  `MARIMO_ALLOW_REMOTE_MCP=1` で opt-in。

**許容する根拠と緩和策:**
- 用途は信頼ネットワーク(家庭内LAN / 社内LAN / VPN)内のPoC運用に限定
- ホスト側ファイアウォール(`ufw` / `firewalld`)で **:80** を絞ること推奨
- 本番化(Step 5)では nginx / Ingress に Basic Auth or OIDC を載せる(Model Y で単一 :80 に
  集約済みなので認証/TLS の差し込みが容易になった)

不特定多数からアクセスされる環境では、本構成を絶対に使わないこと。

### Web 公開(share/publish)機能の無効化

marimo の UI には「Publish HTML to web」「Create WebAssembly link」「Create molab
notebook」といった**ノートブックを外部サービスへ公開**する操作がある。これらは
**marimo サーバ経由ではなくブラウザから外部(`static.marimo.app` / `wasm.marimo.app`
/ `molab.marimo.io`)へ直接送信**されるため、Pod のネットワーク制御では止められない
=社内データ漏洩経路になりうる。

そこで marimo 公式の `[sharing]` 設定で UI ごと無効化している(`images/marimo/Dockerfile`
の marimo.toml に焼き込み済み):

```toml
[sharing]
html = false   # "Publish HTML to web" を隠す
wasm = false   # "Create WebAssembly link" を隠す。両方 false で molab 含む Share 群が全消去
```

- `marimo config show` で `[sharing] html=false wasm=false` を確認できる。
- 公開が必要になったら該当行を `true` に戻す。
- 補足: 「Send feedback」ボタンは残るが、押すと外部リンク(アンケート/GitHub/Discord)へ
  遷移するだけで自動送信は無く、漏洩リスクは低いため無効化していない。
- 標準 AI / GitHub Copilot は config で既定 off(`[ai.models]` 空・`completion.copilot=false`)
  なので、外部 LLM への送信経路も既定で閉じている。

## 今後のステップ(プロジェクトロードマップ)

| Step | 内容 | 状態 |
|---|---|---|
| 1 | 1人での試用(ACP直接公開: claude=3017 / codex=3021 / copilot=3025) | ✅ 完了。`scripts/bootstrap.sh --step 1 --agent <claude\|codex\|copilot>` で再現 |
| 2 | ~~社内ワイルドカードDNS手配~~ | ✅ **不要化(Model Y で DNS 撤廃)**。path-prefix `/nbN/` 振り分けで単一ホスト/IP・:80 のみ |
| 3 | 上司含む2–3人デモ | 未着手 |
| 4 | 複数ユーザー並列 + nginx 振り分け(PoC) | ✅ 完了。`scripts/bootstrap.sh --step 4 --agent <claude\|codex\|copilot>`。Model Y(path-prefix)で `nb1`/`nb2` 並走 |
| 5 | 本番k8s(EKS/GKE/AKS等)へ移行 | 未着手。LoadBalancer / Ingress / TLS / 認証(Basic / OIDC) / 動的テナント発行 |

**Step 4 → Step 5 へ拡張する際の見立て(Model Y 後):**
- `manifests/step4/notebook-nbN.yaml` をテンプレート化(Kustomize / Helm)してユーザー数を可変に
- nginx の path 振り分けを Ingress(Traefik / nginx-ingress)の path ルーティングに置き換え(Host 不要)
- 認証は Ingress 側で oauth2-proxy 等を挟む(単一 :80 集約済みで差し込み容易)
- TLS は cert-manager で社内CAなり Let's Encrypt なり(単一ホスト名で1証明書)
- patched marimo 依存: 上流 `marimo-team/marimo#8531`(ACP WS 相対パス化)がマージされたら
  公式イメージへ戻せる(本リポジトリの fork は「つなぎ」)
