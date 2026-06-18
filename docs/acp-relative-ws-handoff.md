# 引き継ぎ書：marimo fork で ACP WebSocket を相対パス化した（やったことの記録）

> marimo を fork して `getAgentWebSocketUrl` を改造し、ビルド・PR・Docker イメージ化まで
> 行った記録。marimo-envs 側でこの patched イメージを使う際の前提として読む。
> 細かい marimo-envs 側の配線は本書では規定しない（そちら側で判断）。最低限の接続契約だけ §3 に記す。

---

## 1. サマリ（何をしたか）

marimo フロントの ACP WebSocket 接続先を、**エージェント別の固定ポート**
（`ws://host:3017/message` 等）から、**marimo UI と同一オリジンの相対パス**
`<base>/acp/<agentId>` に変更した。変更は `getAgentWebSocketUrl` 1関数（+テスト）。
ビルド（`make fe`）・PR・Copilot レビュー2ラウンド対応・Docker イメージ化（ghcr）まで完了。

これにより「marimo と ACP を同一ホスト・固定ポートで並べる」必要がなくなり、
リバースプロキシで**パスベースの振り分け**ができる状態になった。

---

## 2. ★ 最終 WS パス文字列（厳密）★

パッチ後のフロント（`getAgentWebSocketUrl`）が生成する WebSocket URL。

### 生成規則（厳密）

```
<scheme>://<host>[:<port>]<basePath>/acp/<agentId>
```

- `<scheme>`: `document.baseURI` が `https:` なら **`wss`**、それ以外は **`ws`**
- `<host>[:<port>]`: `document.baseURI` のホスト（＋ポートがあればポート）をそのまま
- `<basePath>`: `document.baseURI` の pathname から**末尾 `/` を除去**したもの
  （ルート配置なら空文字。`/nested/` 等のプレフィックス配下なら `/nested`）
- `/acp/`: 固定リテラル
- `<agentId>`: `encodeURIComponent(agentId)`（`claude` / `codex` / `gemini` / `opencode` / `cursor`）
- **query / hash は付かない**

実装（fork: `frontend/src/components/chat/acp/state.ts`）:

```ts
const url = new URL(document.baseURI);
url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
const basePath = url.pathname.replace(/\/$/, "");
url.pathname = `${basePath}/acp/${encodeURIComponent(agentId)}`;
url.search = "";
url.hash = "";
return url.toString();
```

### ユニットテストで確定した具体例（`state.test.ts` のインラインスナップショット）

| `document.baseURI` | `agentId` | 生成される WS URL（最終文字列） |
|---|---|---|
| `http://localhost:2718/` | claude | `ws://localhost:2718/acp/claude` |
| `https://example.com/` | claude | `wss://example.com/acp/claude` |
| `http://192.168.1.100:8080/` | claude | `ws://192.168.1.100:8080/acp/claude` |
| `https://marimo.example.com/` | gemini | `wss://marimo.example.com/acp/gemini` |
| `https://example.com/nested/` | claude | `wss://example.com/nested/acp/claude` |

---

## 3. marimo-envs 側が満たすべき最小限の接続契約

細かい配線は marimo-envs 側で決めてよいが、**これだけは必要**:

1. **ベースイメージの差し替え**（`images/marimo/Dockerfile`）:
   ```dockerfile
   FROM ghcr.io/phisignet/marimo-patched:${MARIMO_VERSION}
   ```
   下流の `pip install "marimo[mcp]==${MARIMO_VERSION}"` は**そのままで良い**
   （同バージョンの patched marimo が入っているので本体は再インストールされず、
   mcp extras だけ追加され、patched コードは保持される）。

2. **プロキシで `<base>/acp/<agentId>` を ACP サイドカーの `/message` に中継**する
   （WebSocket Upgrade 透過必須）。フロントはもう固定ポートに直接繋がない。
   現状の各サイドカーのポート対応:

   | フロントの agentId | サイドカーのポート | 中継先 |
   |---|---|---|
   | `claude` | 3017 | `/acp/claude` → `…:3017/message` |
   | `codex`  | 3021 | `/acp/codex`  → `…:3021/message` |
   | `cursor` ※ | 3025 | `/acp/cursor` → `…:3025/message` |

   > ※ copilot デプロイは「Cursor の枠（port 3025）を流用」しているため、フロントで
   > 選択される agentId は **`cursor`**、パスも **`/acp/cursor`**（`/acp/copilot` ではない）。

3. ACP 専用ポート（:3017 等）の外部公開は**不要になった**（:80 経由でよい）。
   不要な NodePort / kind の port マッピングは整理できる（判断は marimo-envs 側）。

---

## 4. 私がやった作業の記録

### 4-1. コード変更
- 対象: `frontend/src/components/chat/acp/state.ts` の `getAgentWebSocketUrl`（+ `__tests__/state.test.ts`）
- `AGENT_CONFIG`（ポート定義）は未変更（`getAgentConnectionCommand` が参照するため残置）。

### 4-2. ビルド・検証
- ツール: node `v24.14.0` / pnpm `10.28.2`（`volta install`）/ GNU Make `4.3`
- `make fe` 成功（`real 0m36.333s`、`Compilation succeeded.`）
- フロントテスト 37 件通過 / `oxlint`・`oxfmt --check` クリーン（0 errors）

### 4-3. fork への反映（phisignet/marimo・PUBLIC）
- branch `feature/acp-relative-ws`（最終 commit `9d6a89c12`）
  - `8a7d02a03` feat: 相対パス化（初版）
  - `ff2cdd5ef` fix: `document.baseURI` 基準へ + テスト更新（Copilot 1回目）
  - `9d6a89c12` refactor: `agentId` を `encodeURIComponent`（Copilot 2回目）
- tag `0.23.8-acp` → `9d6a89c12`（Docker ビルドの安定参照点）
- PR **phisignet/marimo#1**（base=`phisignet:main` / draft / 冒頭にエージェント作成を明記）
  - Copilot レビュー2ラウンド対応済み。①テスト破壊→修正、②ベースパス未考慮→`baseURI`基準、
    ③`encodeURIComponent`、④実接続の証跡→「プロキシ配線後に取得」と返信（未取得）。

### 4-4. Docker イメージ
- fork に `docker/Dockerfile.patched`（+ `.dockerignore`）を作成。公式 `:0.23.8`(slim) の drop-in で、
  PyPI install をローカル patched wheel install に差し替えたもの。
- ビルド & push 済み: **`ghcr.io/phisignet/marimo-patched:0.23.8`**（および `:0.23.8-acp`）
- バージョン文字列は静的指定で厳密に `0.23.8`（→ 下流の `==0.23.8` と整合）。
- ⚠️ ghcr 新規パッケージはデフォルト private。kind の pull が通るよう public 化 or `docker login` が必要。

---

## 5. 補足・未了

- **バージョンは 0.23.8 のまま**。パッチはバージョン非依存だが、`--mcp`(experimental) や
  marimo.toml パスを 0.23.8 で検証済みのため、上げるなら別タスク（patched タグ作り直し + 再検証）。
- **実接続の E2E 検証は未実施**（プロキシ配線が前提）。配線後にブラウザ DevTools で
  §2 の最終文字列に対し **101 Switching Protocols** を確認できれば完了。PR #1 に証跡を貼ると親切。
- 上流同方向 issue: marimo-team/marimo#8531（上流マージされたら本 fork は不要になる）。
