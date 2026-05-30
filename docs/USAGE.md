# 利用ガイド(デプロイ後の使い方)

> デプロイ手順とトラブルシューティングは [SETUP.md](SETUP.md) を参照。本書は
> **環境が起動済み**の前提で、ブラウザからエージェントと協働する操作を扱う。

## 1. アクセスと初期表示

| Step | URL |
|---|---|
| Step 1 | `http://localhost:2718/?view-as=present` または `http://<LAN_IP>:2718/?view-as=present` |
| Step 4 | `http://nb1.<LAN_IP>.nip.io/` / `http://nb2.<LAN_IP>.nip.io/`(`/` は自動で `?view-as=present` にリダイレクト) |

- **`?view-as=present` で app view(コード非表示・出力のみ)で開く。** marimo 組み込みの
  起動パラメータで、ノートブックを「アプリ」として見せる。コードを編集したいときは
  右上のトグル(Toggle App View)で通常のエディタ表示に切り替えられる。
- Step 4 は nginx の `:80` listener が `/` を `?view-as=present` にリダイレクトするため、
  URL にパラメータを付けなくても app view で開く。
- bootstrap.sh 完了時の案内 URL にも `?view-as=present` が付与される。

## 2. ノートブックの初期状態

- 初回アクセス時、`/workspace/notebook.py` が存在しなければ marimo が**自動生成**する
  (`marimo edit` に既定ノートブックパス `MARIMO_NOTEBOOK` を渡しているため)。
  手動でファイルを作らなくても、開いてすぐにエージェントと作業を始められる。
- ノートブックは PVC `/workspace` に永続化される。Pod 再作成後も内容は残る。

## 3. エージェントの選択

marimo UI の左サイドバー → エージェントアイコン → ドロップダウンで選ぶ。
**起動時に `--agent` で指定したものを選ぶこと**(別のものを選んでも対応ポートに
ACP サーバーがいないので繋がらない)。

| 起動 `--agent` | UI で選ぶ項目 | ACP port | 備考 |
|---|---|---|---|
| `claude` | **Claude** | 3017 | Claude Code(サブスクトークン) |
| `codex` | **Codex** | 3021 | Codex CLI + Ollama |
| `copilot` | **Cursor** | 3025 | Copilot CLI(Cursor 枠を流用。中身は Copilot) |

> 初回のみ **Settings → Lab → "agents" を有効化**(ブラウザ側設定)。本リポジトリの
> イメージは `external_agents` を焼き込み済みだが、UI 側のフラグは別途必要な場合がある。

WS 接続先はブラウザ JS が `ws://<同じホスト>:<port>/message` でハードコードしている
(エージェント別固定ポート)。詳細は README「設計の核心」を参照。

## 4. エージェントとの協働 — 2つの操作モデル

このリポジトリでは、エージェントがノートブックを変更する経路が2つある。
**通常は marimo-pair(B)が優先**され、より高機能でリアルタイムに反映される。

### A. ファイル編集 + watch + autorun

- エージェントが ACP の `Read`/`Edit`/`Write` で `/workspace/notebook.py` を編集。
- marimo は `--watch` + `watcher_on_save="autorun"` でファイル変更を検知し、
  **変更されたセルを自動実行**する。app view にも即座に反映される。
- どのエージェント(claude/codex/copilot)でも動く素朴な経路。

### B. marimo-pair skill(code_mode で稼働カーネルを直接操作)

- 全エージェントイメージに **marimo-pair skill を焼き込み済み**。エージェントは
  `execute-code.sh` 経由で稼働中の marimo カーネルに直接コードを送り、
  `marimo._code_mode` でセルの作成/編集/実行・パッケージ追加・ウィジェット操作を行う。
- ファイル編集より高機能(リッチ表示・カーネル内省・即時反映)。
- **`code_mode` で作成/編集したセル構造**は `/workspace/notebook.py` に永続化される
  (素のスクラッチパッド実行による一時変数・結果は永続化されない)。

仕組み・配置先・制約の要約は README「エージェントが使えるツール」を参照。

## 5. marimo-pair の使い方

特別な操作は不要。「ノートブックに散布図を追加して」のように依頼すると、
エージェントが skill を読み込み、`code_mode` でセルを追加・実行して画面に反映する。

- **接続は内部的に `--url http://localhost:2718` を使う**(別コンテナのため
  サーバー自動検出 = discovery は使えない。焼き込んだ SKILL.md 冒頭に明記済み)。
- できること: セルの作成/編集/削除・実行、`ctx.packages.add()` でのパッケージ追加、
  anywidget によるカスタムウィジェット、変数・型・shape の内省。
- ガードレール(skill 側で指示済み): ファイル直接編集ではなく `code_mode` を使う、
  パッケージは `ctx.packages.add()` で入れる、など。

## 6. Copilot のモード(Agent / Plan / Autopilot)

Copilot CLI には3つのモードがある(marimo の機能ではなく Copilot 由来。Cursor 枠で
動かしていてもポートに依らず同じ3つが出る)。

| モード | 挙動 |
|---|---|
| **Agent** | 1ターンごとに停止し、ツール実行時に承認を求める(既定運用) |
| **Plan** | プランを作成して提示する |
| **Autopilot** | `task_complete` まで自動継続。全ツール権限を自動承認 |

### ⚠️ Autopilot を使うときの注意

Autopilot を**いきなり選ぶと** `Permission service is unavailable for this session.`
(-32603)で失敗する。これは Copilot CLI の ACP モードで permission service が
遅延初期化される(初回のツール権限チェック時に生成)ことに起因する既知の挙動。

**回避策(フラグ不要):**

1. まず **Agent モードで一度やり取り**する(ツール実行を1回走らせる)。
   → これで permission service が初期化される。
2. その後 **Autopilot に切り替える**と成功する。Agent モードの承認はそのまま残る。

全自動運用(human-in-the-loop なし)が必要なら、Copilot 起動コマンドに `--yolo`
(=`--allow-all`)を付ける方法もあるが、**全モードで承認が一切なくなる**(シェル・
ファイル書込含む)ため、複数人共有(Step 4)では危険。常用は非推奨。

## 7. 事前インストール済みパッケージ

marimo カーネル(コード実行側)には主要な分析ライブラリを事前導入済み。`import` が
即座に通る(エージェントが毎回インストールする待ち時間を省く):

`numpy` / `pandas` / `matplotlib` / `seaborn` / `altair` / `plotly` / `polars` /
`pyarrow` / `scikit-learn` / `scipy` / `statsmodels`

不足するライブラリは、エージェントに `ctx.packages.add("<pkg>")` で追加させるか、
Pod 内で `pip install` する(ランタイムでも書き込めるよう所有権を調整済み)。

## 8. 操作例(依頼プロンプト)

- 「`seaborn` のサンプルデータで散布図を描くセルを追加して」
- 「この DataFrame の各列の欠損数を集計するセルを作って」
- 「スライダー(`mo.ui.slider`)で閾値を変えてグラフが更新されるようにして」
- 「現在のノートブックのエラーを調べて直して」(MCP の `get_notebook_errors` を使う)

## 9. 既知の注意

- **Autopilot はいきなり選べない**(§6 の回避策)。
- marimo-pair の **discovery は使えない**(別コンテナ)。エージェントは常に
  `--url http://localhost:2718` を使うよう skill で指示済み。
- 本構成は `--no-token` / 平文 HTTP・WS 前提(信頼ネットワーク内 PoC)。
  セキュリティ前提は SETUP.md「MCP のセキュリティ前提」を参照。
