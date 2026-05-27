# Copilot Agent 統合 設計ドキュメント

> **ステータス**: 実装済(2026-05-27 設計 → 2026-05-28 実装完了)
>
> **担当ブランチ**: `feat/copilot-agent`
>
> **対象 PR**: [#6](https://github.com/phisignet/marimo-envs/pull/6)(レビュー対応中)
>
> 本ドキュメントは設計時点(2026-05-27)の意図と決定事項を保存する記録物。
> 実装の最終形は同 PR のコード(`images/copilot-acp/` / `manifests/step{1,4}/copilot/` /
> `scripts/bootstrap.sh` 等)が source of truth であり、本ドキュメントの 5 章
> 「詳細仕様」のコードスニペットは**設計時点の参考**として残している
> (細部は実装側で発展済 — 例: tini 経由起動、`USER node`、env unset 戦術等)。

## 1. 背景と動機

### 1.1 現状の制約

本リポジトリは Step × Agent の 4 組合せ(Step 1/4 × claude/codex)をサポート済([README.md](../README.md))。会社環境では Codex + Ollama 構成での運用を目指すが、以下の制約に直面している:

- **GPU vRAM 制約**: 会社 Ollama サーバーの GPU vRAM が小さく、`gemma4:e4b` 程度のモデルしか動かせない
- **小型モデルの tool calling 性能不足**: `gemma4:e4b` は `/v1/responses` で `tool_calls` を返すが、Codex の長大なシステムプロンプト下では「ファイル一覧」のような単純依頼にも tool を呼ばず質問返ししてくる instruction following 限界がある(詳細: [[codex-small-model-tool-issue]] memory)
- **クラウド系小型モデルでも改善限定**: `gemma3n` 系は tool calling 学習が薄く Codex 用途に向かない

### 1.2 Copilot CLI を選ぶ理由

- 会社環境で **既に Copilot サブスクリプション** が承認・利用可能
- Copilot CLI は **公式に ACP プロトコル対応**([2026-01-28 public preview](https://github.blog/changelog/2026-01-28-acp-support-in-copilot-cli-is-now-in-public-preview/))。新規実装不要
- バックエンドは GPT-5 系の高性能モデルで、tool calling 性能は本件用途で十分以上
- 会社の GPU・vRAM 制約を完全に回避(推論は Microsoft/GitHub クラウド)

### 1.3 既存戦術との対比

| 項目 | Codex + Ollama | **Copilot CLI**(本提案) | Claude Code |
|---|---|---|---|
| 推論バックエンド | 社内/家内 Ollama | GitHub クラウド | Anthropic |
| 認証 | 不要 | GitHub PAT(`COPILOT_GITHUB_TOKEN`) | OAuth トークン |
| データ送信先 | 社内/家内 | GitHub/Microsoft | Anthropic |
| 会社コンプラ | 適合 | **適合(既承認)** | NG ケースあり |
| 性能 | モデル次第 | 安定して高性能 | 高性能 |

## 2. 戦術: marimo の Cursor port (3025) を Copilot CLI で流用

marimo の ACP 接続は `getAgentWebSocketUrl(agentId)` で agentId ごとに **固定 port** を返す仕様([フロントエンド state.ts](https://github.com/marimo-team/marimo/blob/main/frontend/src/components/chat/acp/state.ts) の `AGENT_CONFIG`):

```
claude=3017, gemini=3019, codex=3021, opencode=3023, cursor=3025
```

これは厳密に「marimo の Lab 機能で UI 上のエージェント選択肢として表示される枠」の port マッピング。**実体としてはどのポートも単に「ACP プロトコルを話す WebSocket サーバー」が居れば良い**ので、本提案では以下を行う:

- Cursor 用 port **3025 に Copilot CLI を `stdio-to-ws` で乗せる**
- marimo UI 上は「Cursor」と表示されるが中身は Copilot
- 同じ流儀の先行事例として、marimo 公式チュートリアルが [OpenCode を Claude port 3017 に乗せる用法](https://docs.marimo.io/guides/editor_features/agents/) を案内している

### 2.1 ローカル動作確認(2026-05-27)

adams ヘッドレス上で動作確認済:

```bash
export COPILOT_GITHUB_TOKEN='github_pat_xxx'  # Fine-grained PAT(Copilot Requests 権限)
npx -y stdio-to-ws "copilot --acp --stdio" --port 3025
# 別ターミナル
marimo edit --no-token --host 0.0.0.0 --port 2718
# 別 PC ブラウザから http://adams:2718/ → Agents パネルで Cursor 選択 → 接続成功
```

`session/new` まで通って、Copilot がユーザーメッセージに応答することを確認(詳細: [[copilot-cli-acp-integration]] memory)。

## 3. アーキテクチャ

### 3.1 Pod 構成(Step 1)

```
Pod: marimo
├── container: marimo
│   - image: marimo-envs/marimo:0.1.0
│   - port: 2718 (marimo UI)
└── container: copilot-acp(新規)
    - image: marimo-envs/copilot-acp:0.1.0
    - port: 3025 (Copilot ACP via stdio-to-ws)
    - env:
        COPILOT_GITHUB_TOKEN: from Secret copilot-token
    - volumeMounts:
        - workspace: PVC (marimo-workspace)

Service: marimo
- ClusterIP + NodePort(Step 1) or ClusterIP のみ(Step 4)
- ports:
    - marimo: 2718 → NodePort 30718
    - acp:    3025 → NodePort 30325
```

### 3.2 Pod 構成(Step 4)

```
Pod: nginx-gateway(既存)
- nginx :80 → marimo :2718(各テナント)
- nginx :3025 → copilot-acp :3025(各テナント、Host ヘッダで振り分け)

Pods: marimo-nb1, marimo-nb2
- 上記 Step 1 の Pod 構成を nb1/nb2 で 2 つ複製
- 全テナントで同じ COPILOT_GITHUB_TOKEN を共有(Secret は 1 つ)

kind cluster:
- extraPortMappings に 3025 追加
  - claude=3017, codex=3021 と並んで copilot=3025
  - 全 agent port を同時 bind することで Step 内での agent 切替時に
    cluster 再作成不要を維持(既存方針との整合)
```

### 3.3 認証フロー

```
GitHub Copilot Pro/Business/Enterprise アカウント
    ↓ (Web UI で発行)
GitHub Fine-grained PAT (Personal Access Token)
    - Resource owner: 個人アカウント(組織だと Copilot Requests permission が出ない)
    - Account → Copilot Requests を Read 付与
    - ⚠️ Classic PAT (ghp_*) は Copilot CLI で非対応、必ず Fine-grained
    ↓ (kubectl create secret --from-file=token=...)
Kubernetes Secret: copilot-token
    ↓ (Pod の env で参照)
Pod 内 env: COPILOT_GITHUB_TOKEN
    ↓ (entrypoint.sh が起動)
copilot --acp --stdio が env を読んで認証
```

**重要**: PAT は env 経由のみ。`~/.copilot/config.json` の OAuth 永続化(headless で挙動が不安定なバグ確認済)は使わない。

## 4. ファイル構成

新規追加・既存修正の差分:

```
images/copilot-acp/                 [新規]
├── Dockerfile                       node + @github/copilot + stdio-to-ws
└── entrypoint.sh                    env 確認 + stdio-to-ws "copilot --acp --stdio" --port 3025

manifests/step1/copilot/             [新規]
├── kustomization.yaml               base + Service + Secret + Patch
├── acp-patch.yaml                   marimo Deployment に copilot-acp sidecar 注入
└── service.yaml                     NodePort 30325(2718+30718 と並列)

manifests/step4/copilot/             [新規]
├── kustomization.yaml
├── nginx-configmap.yaml             nginx 設定(:80 + :3025 を listen、Host ヘッダ振り分け)
├── nginx-deployment.yaml            NodePort 30080 + 30325
├── notebook-nb1.yaml                marimo + copilot-acp サイドカー
└── notebook-nb2.yaml                同上

scripts/bootstrap.sh                 [修正]
- --agent copilot 分岐追加
- copilot 用 Secret 作成(既存 claude の mktemp + chmod 600 + --from-file パターン踏襲)
- COPILOT_GITHUB_TOKEN env チェック(claude の CLAUDE_CODE_OAUTH_TOKEN と同じ流儀)

scripts/lib/common.sh                [修正]
- (備考) acp_node_port マッピングは bootstrap.sh 側にあるためそちらで対応

kind/cluster-step1.yaml              [修正]
- extraPortMappings に { containerPort: 30325, hostPort: 3025 } 追加
- 既存コメント(両 ACP ポート bind の前提と回避策)を copilot 含めた 3 ポート版に更新

kind/cluster-step4.yaml              [修正]
- 同上、hostPort: 3025 追加

README.md                            [修正]
- 統合 CLI 使用例に --agent copilot を追加
- Agent 比較表に Copilot 行を追加(認証要件、推論先、コンプラ位置付け)

docs/SETUP.md                        [修正]
- 3-A / 3-B 手順に copilot 版を追記
- 「LAN の他PC から繋がらない」項目に headless ホストでのファイアウォール注意を強化
  (kind 経由ではない素直接公開ケースも明記、今回学んだやつ)
```

## 5. 詳細仕様

### 5.1 `images/copilot-acp/Dockerfile`

**(設計時点のスケッチ。実装の最終形は [`images/copilot-acp/Dockerfile`](../images/copilot-acp/Dockerfile) を参照)**

実装時に判明・調整した点:
- ベースは `node:22-slim`(設計時 `node:20-bookworm-slim` から変更、既存 acp-agent と揃える)
- 非 root ユーザーは `node`(既存 node イメージに含まれる uid 1000)を流用、`useradd` 不要
- PID 1 シグナル処理に `tini` を導入(他サイドカーと統一)
- `ca-certificates` を明示インストール(HTTPS 検証用、Copilot API が GitHub HTTPS)
- バージョン pin は `@github/copilot@1.0.54` + `stdio-to-ws@0.2.0`(public preview のため)

設計時のスケッチ(参考、実装と完全一致するものではない):

```dockerfile
# このスニペットは設計時点の意図を残すための参考。
# 実装最終形は images/copilot-acp/Dockerfile を参照のこと。
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g stdio-to-ws@0.2.0 @github/copilot@1.0.54
COPY --chown=node:node entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
USER node
WORKDIR /workspace
EXPOSE 3025
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
```

### 5.2 `images/copilot-acp/entrypoint.sh`

```bash
#!/bin/sh
# Copilot ACP サイドカー起動時に、COPILOT_GITHUB_TOKEN を確認して
# stdio-to-ws + copilot --acp --stdio を port 3025 で起動する。
set -e

if [ -z "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "[entrypoint] ERROR: 環境変数 COPILOT_GITHUB_TOKEN が未設定です。" >&2
    echo "[entrypoint]        GitHub PAT(Copilot 利用権限あり)を Secret 経由で渡してください。" >&2
    exit 1
fi

# Copilot CLI 用クレデンシャル優先順位:
#   COPILOT_GITHUB_TOKEN > GH_TOKEN > GITHUB_TOKEN > keychain > gh auth token
# Pod 内では COPILOT_GITHUB_TOKEN のみセット、他は unset しておく
# (env 干渉で 401 ループする罠回避、ローカルで学んだやつ)
unset GH_TOKEN GITHUB_TOKEN

echo "[entrypoint] Starting Copilot ACP server on port 3025..."
exec stdio-to-ws "copilot --acp --stdio" --port 3025
```

### 5.3 `manifests/step1/copilot/acp-patch.yaml`

claude/codex の `acp-patch.yaml` と同じ strategic-merge-patch 形式。差分:

```yaml
- image: marimo-envs/copilot-acp:0.1.0(新規イメージタグ)
- containerPort: 3025
- env: COPILOT_GITHUB_TOKEN from Secret(claude の CLAUDE_CODE_OAUTH_TOKEN 同等)
```

### 5.4 `scripts/bootstrap.sh` 分岐追加

claude 分岐に倣う:

```bash
elif [[ "$AGENT" == "copilot" ]]; then
    if [[ -z "${COPILOT_GITHUB_TOKEN:-}" ]]; then
        die "環境変数 COPILOT_GITHUB_TOKEN が未設定です。

  1) https://github.com/settings/personal-access-tokens/new で Fine-grained PAT を発行
     Resource owner: 個人アカウント / Account → Copilot Requests を Read
     (Classic PAT は Copilot CLI で非対応)
  2) この端末で:
       export COPILOT_GITHUB_TOKEN='github_pat_xxx...'
       ./scripts/bootstrap.sh --step ${STEP} --agent copilot"
    fi
fi
```

Secret 作成も claude 同パターン(mktemp + chmod 600 + trap EXIT + `--from-file=token=`):

```bash
if [[ "$AGENT" == "copilot" ]]; then
    token_file=$(mktemp)
    trap 'rm -f "$token_file"' EXIT
    printf %s "$COPILOT_GITHUB_TOKEN" > "$token_file"
    chmod 600 "$token_file"
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic copilot-token \
        --from-file=token="$token_file" \
        --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
fi
```

### 5.5 NodePort 衝突検知の拡張

`scripts/bootstrap.sh` の NodePort マッピング:

```bash
case "$AGENT" in
    claude)  acp_node_port=30317 ;;
    codex)   acp_node_port=30321 ;;
    copilot) acp_node_port=30325 ;;
esac
```

`acp_node_port` 周辺の case 文を 3 値対応に拡張。allowed_service_name は Step 1=marimo / Step 4=nginx-gateway のロジック不変。

### 5.6 nginx (Step 4) 拡張

`nginx-configmap.yaml` で `:3025` の listen ブロックを追加。Host ヘッダ `nbN.<IP>.nip.io` で各テナント Pod の `:3025`(copilot-acp service)に proxy_pass。既存の :3017 / :3021 ブロックと同じ形。

## 6. ハマりどころと対策

ローカル動作確認で遭遇した罠を Pod 化時に再発させない対策:

| 罠 | 対策 |
|---|---|
| `GH_TOKEN`/`GITHUB_TOKEN` env 干渉で 401 ループ | entrypoint.sh で `unset GH_TOKEN GITHUB_TOKEN`(本ドキュメント 5.2) |
| `claude-code-acp` 未インストールで ENOENT | Docker image に明示的に npm install で含める(Dockerfile に pin で記述) |
| `copilot --acp --stdio` の child process が wscat 切断で死ぬ | marimo は long-lived 接続なので問題ない。stdio-to-ws の挙動として既知 |
| ヘッドレス OS で `~/.copilot/config.json` 平文保存が次回読まれないバグ | env のみで認証、`~/.copilot/` 一切使わない |
| marimo UI で「Cursor」と出るが中身 Copilot | 暫定容認。本実装時に AGENT_CONFIG パッチを検討する場合は別 PR |
| **未確認**: Codex 経由の bubblewrap エラーと同類が Copilot で出るか | Pod 内で実際に shell tool 呼び出しテスト必須 |
| **未確認**: ACP protocol version 1 が marimo 最新版とずれていないか | ローカルで `protocolVersion: 1` 往復成功確認済、Pod でも同じはず |

## 7. テスト計画

### 7.1 ローカル動作確認(済)

- [x] adams で `copilot --acp --stdio` 単体動作
- [x] adams で `stdio-to-ws "copilot --acp --stdio" --port 3025` 経由 marimo 接続
- [x] 別 PC ブラウザから接続 + チャット欄表示 + `Hi` への応答確認

### 7.2 PR マージ前(本実装後)

- [ ] `docker build images/copilot-acp/` でイメージ作成
- [ ] `./scripts/bootstrap.sh --step 1 --agent copilot` でクラスタ起動
- [ ] Pod 内で `kubectl exec -- copilot --version` 等で CLI 動作
- [ ] ブラウザから marimo + Cursor(=Copilot) 接続成功
- [ ] **shell tool 実行テスト**: 「カレントディレクトリのファイルを一覧して」「git status を実行して」等で実際に exec_command が動くか
- [ ] `./scripts/bootstrap.sh --step 4 --agent copilot` で複数テナント並走テスト
- [ ] nb1/nb2 それぞれで独立に Copilot との会話が成立

### 7.3 会社環境での最終確認(マージ後)

- [ ] 会社の Ollama サーバー上(または社内 k8s)で同手順
- [ ] 会社 PAT で認証
- [ ] 実業務(データ分析依頼)で gemma4:e4b では呼べなかった shell tool が動くか

## 8. オープン課題 / 将来検討

- **`--agent copilot` の bootstrap.sh 内 env 変数名**: 現状 claude=`CLAUDE_CODE_OAUTH_TOKEN`, codex=`OLLAMA_BASE_URL` という流儀。copilot は `COPILOT_GITHUB_TOKEN` 一つだけで十分(モデル選択も不要、Copilot バックエンドが固定)
- **3 ACP port 同時 bind による hostPort 競合リスク**: Step 1/4 ともに `extraPortMappings` に 3017/3021/3025 を bind するため、ホスト側いずれかが占有されていると kind create が失敗。既存の 2 ポート bind と同じ仕組みなので、`kind/cluster-step*.yaml` のコメントを更新する
- **GitHub Enterprise Server 対応**: 会社が GHES を使っている場合、Copilot CLI に GHES エンドポイント設定が必要かも。現状未調査
- **MCP 統合**: 既存の Claude/Codex 構成では marimo の MCP サーバーをサイドカー側に自動登録している。Copilot CLI も MCP クライアントを持つので統合可能なはず。本 PR スコープ外で別途検討

## 9. レビュー観点(レビュアー向け)

- [ ] 戦術(Cursor port 流用)が marimo の今後の AGENT_CONFIG 変更で壊れる可能性をどう見るか
- [ ] PAT のスコープ要件(Fine-grained PAT に Copilot Requests 権限、Resource owner = 個人アカウント)
- [ ] entrypoint.sh の `unset GH_TOKEN GITHUB_TOKEN` を Pod 内でやって問題ないか(他のツールが必要としていないか)
- [ ] イメージ build 戦略(buildx / multi-arch 必要か、現状 amd64 のみで十分か)
- [ ] ファイル構成が既存の claude/codex 構成と平仄揃っているか
- [ ] Step 4 nginx の :3025 ブロック追加が既存 :3017 / :3021 と同型か

---

**レビューOK後の実装フェーズ:**
本ドキュメントの 5 章(詳細仕様)に従って実装 → 7.2 テスト → PR(本 draft を昇格)→ マージ。
