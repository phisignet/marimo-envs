# 設計メモ: Model Y（path-prefix テナント分離・DNS 廃止）

> patched marimo（`ghcr.io/phisignet/marimo-patched:0.23.8`、ACP WS = `<base>/acp/<agentId>`）
> を前提に、marimo_envs のネットワーク層を作り替える設計。実装はこのメモに従う。
> 契約は [acp-relative-ws-handoff.md](acp-relative-ws-handoff.md) §2/§3。

## 目的

- ACP 専用ポート（3017/3021/3025）と nip.io ワイルドカード DNS を**撤去**。
- **単一ホスト/IP・単一 :80** で多テナントを実現（テナント＝パス prefix）。
- アクセス: `http://<LAN_IP>/nbN/?view-as=present`（Step 4）、`http://<LAN_IP>/?view-as=present`（Step 1）。

## 実機検証で確定した前提（重要）

- patched イメージの ACP WS 生成 = `${baseURI.pathname の末尾/除去}/acp/${encodeURIComponent(agentId)}`（検証済み）。
- `marimo --base-url /nb1` は **全配信を `/nb1/` 配下にする**（`/`→404、`/nb1/`→200、assets も `/nb1/`）。nginx は **prefix を剥がさず素通し**。
- **`--base-url /nb1` 時の healthz は `/nb1/healthz`**（readinessProbe のパスを prefix 付きにすること。さもないと 404 で永遠に Ready にならない）。
- **`--base-url /nb1` 時は MCP サーバ URL も `/nb1/mcp/server`** にプレフィックスされる（実機確認済み）。claude サイドカー(acp-agent)の `claude mcp add` 先を Step 4 では `http://localhost:2718/nbN/mcp/server` に直す（`MARIMO_MCP_URL` env で注入）。Step 1（base-url なし）は既定の `/mcp/server` のままで良い。codex/copilot サイドカーは marimo MCP を登録しないため影響なし。

## 目標構成

```
ブラウザ http://<IP>/nb1/?view-as=present
   ↓ nginx :80（唯一の公開ポート / NodePort 30080）
   location ^~ /nb1/acp/ → (rewrite ^ /message) → marimo-nb1 サイドカー :<acpPort>
   location ^~ /nb1/     → marimo-nb1 marimo :2718（prefix 非ストリップ・WS透過）
   location ^~ /nb2/acp/ → marimo-nb2 サイドカー /message
   location ^~ /nb2/     → marimo-nb2 marimo :2718
   location /            → 404（/nbN/ への案内）
Step1: location ^~ /acp/ → サイドカー /message、location / → marimo（base-url なし）
```

- `<acpPort>` は agent 種別で決まる: claude=3017 / codex=3021 / cursor=3025（copilot は cursor 枠流用）。
- ACP の rewrite: `/nbN/acp/<id>`（id は UI 選択値）→ サイドカーは `/message` のみ提供。pod 内サイドカーは1つなので id は経路上無視し全て `/message` へ。

## nginx ロケーション設計（要点）

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

# ACP（より長い prefix を ^~ で先に確定）
location ^~ /nb1/acp/ {
  rewrite ^ /message break;              # 全 URI を /message に
  proxy_pass http://marimo-nb1...:<acpPort>;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_set_header Host $host;
}
# marimo 本体（prefix を保持＝proxy_pass に URI を付けない）
location ^~ /nb1/ {
  proxy_pass http://marimo-nb1...:2718;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade; # marimo 自身の /nb1/ws 用
  proxy_set_header Connection $connection_upgrade;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

- `^~` で「prefix マッチ確定（正規表現に奪われない）」。longest-prefix で `/nb1/acp/` が `/nb1/` より先。
- proxy_pass の URI 有無がキモ: ACP は `rewrite ... break` で `/message` 固定、marimo は URI 無しで元パス（`/nb1/...`）保持。

## 各ファイルの to-be

### marimo イメージ `images/marimo/Dockerfile`
- `FROM ghcr.io/phisignet/marimo-patched:${MARIMO_VERSION}`（公式→patched）。
- `ENV MARIMO_BASE_URL=""`。CMD で空でなければ `--base-url "$MARIMO_BASE_URL"` を付与。
- `pip install marimo[mcp]==…` 後に **patched 資産（`/acp/` を含む agent-panel JS）が残っているか build 内 assert**。

### Step 1 `manifests/step1/`
- `base/marimo-deployment.yaml`: 変更なし（marimo コンテナのみ）。
- `<agent>/acp-patch.yaml`: 変更なし（サイドカー追加）。
- `<agent>/service.yaml`: **NodePort → ClusterIP**。ports = marimo:2718 + acp:<port>（nginx からのみ参照）。
- `<agent>/nginx-configmap.yaml`: **新規**。`/acp/`→サイドカー/message、`/`→marimo:2718。
- `<agent>/nginx-deployment.yaml`: **新規**。nginx-gateway(:80) + NodePort Service(30080)。
- `<agent>/kustomization.yaml`: nginx-configmap / nginx-deployment を resources に追加。

### Step 4 `manifests/step4/`
- `<agent>/notebook-nbN.yaml`:
  - marimo コンテナに `MARIMO_BASE_URL=/nbN` を追加。
  - **readinessProbe path を `/nbN/healthz` に**。
  - Service は ClusterIP のまま（marimo + acp）。nip.io コメント撤去。
- `<agent>/nginx-configmap.yaml`: host 振り分け → **path-prefix 振り分け**に全面書き換え（上記設計）。
- `<agent>/nginx-deployment.yaml`: nginx コンテナ/Service から **:3017 等 ACP ポート削除**。:80(30080) のみ。

### kind `kind/cluster-step1.yaml` / `cluster-step4.yaml`
- ACP ポート（3017/3021/3025）と step1 の 2718 マッピングを**削除**。
- 両方とも **:80 → node 30080** に集約（step1 も nginx :80 経由になるため）。

### `scripts/bootstrap.sh`
- 案内 URL: step1 `http://<IP>/?view-as=present` / step4 `http://<IP>/nbN/?view-as=present`。
- NodePort 衝突チェック・必須ポート: 両 Step とも **30080 のみ**（ACP NodePort ロジック撤去）。
- 最終メッセージの WS 説明: `ws(s)://<host>/[nbN/]acp/<id>`（固定ポート記述を撤去）。

### ドキュメント
- README / SETUP / USAGE: nip.io 撤去、新アクセスモデル、ACP は path 経由、patched イメージ前提。
- `acp-relative-ws-handoff.md` を本 PR でコミット（契約として保持）。

## 撤去物リスト

- nip.io / Host ヘッダ振り分け（server_name 正規表現）。
- ACP 専用 NodePort（30317/30321/30325）と kind hostPort（3017/3021/3025）。
- step1 の marimo 直 NodePort（30718 / 2718）。

## 検証（Phase 8）

- 静的: `docker build images/marimo`（パッチ残存 assert）/ `kubectl kustomize` 全 6 overlay / 各 nginx.conf を `nginx -t` 構文チェック / `./scripts/test.sh`。
- **e2e（要デプロイ・トークン）**: deploy 後ブラウザ DevTools で `ws://<IP>/nbN/acp/<id>` に **101 Switching Protocols**。fork 側も e2e 未検証なので、ここが WS パッチの初実地。

## 既知のリスク / 留意

- nginx の rewrite + WS 透過 + location 優先度はデプロイするまで実挙動未確認（静的に nginx -t まで）。
- marimo `--base-url` 配下の各エンドポイント（/nbN/ws 等）が proxy 越しで動くかは e2e で確認。
- patched イメージは 0.23.8 固定。上げる時は fork 側で patched タグ作り直し + 本構成の再検証。
