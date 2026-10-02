# PostgreSQL パフォーマンスチューニング実践ラボ

「実務である日突然、クエリが遅くなった」を疑似体験するための練習リポジトリです。
TODOアプリ風のスキーマ(`users` 100,000件 / `todos` 1,000万件)を用意し、
`EXPLAIN (ANALYZE, BUFFERS)` を読みながらボトルネックを特定 → 修正 → 再計測、という
実務のチューニングサイクルを手を動かして体験できます。

設定は意図的にDockerイメージのデフォルトのままにしています(`shared_buffers`,
`work_mem` などをチューニング済みにしてしまうと練習になりません)。

全5シナリオを収録しています。シナリオ1・2が基礎編(インデックス欠如 / メモリ設定と
I/Oバウンドの切り分け)、シナリオ3〜5が上級編(インデックス種別の選択、`OFFSET`の
構造的な限界、sargability/条件の書き方)です。

## セットアップ

```bash
docker compose up -d
# 初回起動時は1,000万行のINSERTが走るため1〜2分ほどかかります
docker compose logs -f postgres   # "database system is ready to accept connections" が出たらOK
```

接続:

```bash
docker exec -it pg-perf-lab psql -U postgres -d perf_test
```

後片付け(ボリュームごと削除してまっさらな状態に戻す):

```bash
docker compose down -v
```

## 前提スキーマ

```
users(id, name, email, created_at)
todos(id, user_id -> users.id, title, completed, created_at)
```

`todos.user_id` は外部キーですが、**インデックスは張られていません**。
Postgresは外部キー列に自動でインデックスを作らないため、これは実務でも頻発する
「あるある」な初期状態です。

---

## シナリオ1: 「ユーザーのTODO一覧ページが遅い」

マイページで直近のTODOを20件表示するだけの、ごく普通のクエリです。

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, title, completed, created_at
FROM todos
WHERE user_id = 42
ORDER BY created_at DESC
LIMIT 20;
```

### やってみる

1. 上のクエリを実行し、実行計画と実行時間を確認する
2. `Parallel Seq Scan` や `Rows Removed by Filter` の数字に注目し、何が起きているか説明してみる
3. 原因を解消するインデックスを設計して `CREATE INDEX` する
4. 再度 `EXPLAIN (ANALYZE, BUFFERS)` を実行し、どのNodeがどう変わったか比較する
5. 余力があれば「`ORDER BY` のソートも消す」ところまで踏み込んでみる

<details>
<summary>解答・解説を見る</summary>

#### 初期状態(実測 約760ms)

```
Limit (actual time=581.579..588.326 rows=20 loops=1)
  -> Gather Merge
       -> Sort
            Sort Key: created_at DESC
            -> Parallel Seq Scan on todos
                 Filter: (user_id = 42)
                 Rows Removed by Filter: 3333299
Execution Time: 761.720 ms
```

1,000万行の `todos` を並列ワーカーで総なめして `user_id = 42` を探しているため、
ほとんどの行(`Rows Removed by Filter`)を読んでは捨てている。並列化のおかげで
致命的な遅さにはなっていないが、本番で負荷がかかればすぐ詰まる。

#### 対処1: `user_id` に単純インデックス

```sql
CREATE INDEX idx_todos_user_id ON todos(user_id);
```

→ 約760ms → **約1.3ms**(約580倍)。`Bitmap Index Scan` でuser_id=42の約100行だけ
特定できるようになった。ただし `ORDER BY created_at DESC` のための `Sort` ノードは
まだ残っている(top-Nヒープソートなので実害はほぼないが、理論上は毎回ソートが発生)。

#### 対処2: 複合インデックスでソートごと消す

```sql
DROP INDEX idx_todos_user_id;
CREATE INDEX idx_todos_user_id_created_at ON todos(user_id, created_at DESC);
```

→ **約0.1ms**(初期状態比で約6,600倍)。`Sort` ノードが実行計画から完全に消え、
`Index Scan` だけで `WHERE` と `ORDER BY` の両方を満たせるようになった。

**学び**: 「`WHERE col = ?` だから `col` にインデックス」で終わらせず、
`ORDER BY` / `LIMIT` まで含めてアクセスパターンを見て複合インデックスの列順序を
設計すると、ソートそのものを消せることがある。

</details>

---

## シナリオ2: 「管理画面の集計レポートが重い」

「ユーザーごとの未完了TODO件数ランキング」を表示する管理機能です。

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u.name, count(*) AS incomplete_count
FROM todos t
JOIN users u ON u.id = t.user_id
WHERE t.completed = false
GROUP BY u.id, u.name
ORDER BY incomplete_count DESC
LIMIT 10;
```

シナリオ1を解決した後のインデックスがある状態からスタートしてOKです
(このクエリに対してはあまり効きません、理由は解答参照)。

### やってみる

1. `completed` の値の分布を確認する(`SELECT completed, count(*) FROM todos GROUP BY completed;`)
2. 実行計画の `HashAggregate` / `Sort` 付近にある `Batches` や `Disk Usage` に注目する
3. 「これはインデックスの問題か? メモリ設定の問題か? I/Oの問題か?」を切り分ける
4. `work_mem` を変えて(`SET work_mem = '64MB';`)同じクエリを再実行し、何が変わって何が変わらないか確認する

<details>
<summary>解答・解説を見る</summary>

#### 初期状態(実測 約1.6秒)

```
Partial HashAggregate
  Batches: 5  Memory Usage: 8241kB  Disk Usage: 31696kB
  -> Hash Join
       -> Parallel Seq Scan on todos t
            Filter: (NOT completed)
            Rows Removed by Filter: 1667140
Execution Time: 1623.404 ms
```

- `completed` はほぼ50/50の分布なので、ここにインデックスを張っても
  選択性が低すぎて意味がない(結局テーブルの半分を読むことになる)
- 本当の問題は `work_mem`(デフォルト4MB)が集計のワーク領域に対して小さすぎ、
  `HashAggregate` が **ディスクに溢れている**(`Batches: 5`, `Disk Usage`)こと

#### `work_mem` を増やす

```sql
SET work_mem = '64MB';
```

→ `Batches: 1` になりディスクスピルは解消するが、実行時間は **約1.54秒** と
ほとんど変わらない。

**ここが今回のシナリオの肝**: 最初に見つけた問題(ディスクスピル)を直しても
体感速度が変わらないことがある、という実務でよくある「当たりを外す」経験その
ものを再現しています。実際のボトルネックは `Parallel Seq Scan on todos` が
1,000万行の約半分(500万行)を毎回ディスクから読んでいる、純粋なI/Oコストです。
`completed = false` の行は全体の半分もあるため、インデックスを使っても
結局ほぼ同じ量の行を読む必要があり、インデックスでは解決しません。

**この場合の現実的な対処(ここでは実装しません。設計の選択肢として検討してみてください)**:
- このレポートが頻繁に叩かれるなら、都度集計ではなく「未完了件数」を
  ユーザーごとに持つサマリーテーブル/カウンタを用意し、TODOの作成・完了時に
  インクリメンタルに更新する
- 頻度が低い管理画面バッチなら、「集計に1.5秒かかる」こと自体を許容し、
  実行頻度やキャッシュ(マテリアライズドビューなど)で緩和する
- `completed` のような低カーディナリティ列は、インデックスではなく
  クエリ頻度とデータ特性から設計を見直す対象と考える

**学び**: `EXPLAIN ANALYZE` の数字を直しても体感速度が変わらないことがある。
「ディスクスピルしている」と「それがボトルネックである」は別の話であり、
`Execution Time` の変化で都度検証しないと誤った最適化に時間を使ってしまう。

</details>

---

## シナリオ3(上級): 「検索機能が遅い」

タイトルの部分一致検索(前方一致ではなく「含む」検索)を追加したところ、遅いと報告が来ました。

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM todos WHERE title LIKE '%4242%';
```

### やってみる

1. 上のクエリを実行し、なぜ`todos_pkey`や他のインデックスが使われないのか考える
2. B-treeインデックスが`LIKE '%...%'`(前方に`%`がある=前方一致でない)を苦手とする理由を説明してみる
3. `pg_trgm`拡張を使って解決する

<details>
<summary>解答・解説を見る</summary>

#### 初期状態(実測 約393ms)

```
Parallel Seq Scan on todos
  Filter: (title ~~ '%4242%'::text)
  Rows Removed by Filter: 3332007
Execution Time: 393.073 ms
```

B-treeインデックスは値を辞書順に並べた木構造なので、`前方一致`(`LIKE 'foo%'`)には
範囲検索として使えますが、`%foo%`のように先頭が不定な条件では「どこから探せばいいか」
がわからず活用できません。結果、他にインデックスがあってもこの条件だけは全表走査になります。

#### 対処: `pg_trgm` + GINインデックス

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_todos_title_trgm ON todos USING gin (title gin_trgm_ops);
```

→ 約393ms → **約20ms**(約19倍)。`pg_trgm`は文字列を3文字(トライグラム)単位に
分解してインデックス化するため、`%`が先頭にあっても「含む」検索を高速化できます。

```
Bitmap Index Scan on idx_todos_title_trgm
  Index Cond: (title ~~ '%4242%'::text)
```

**学び**: 「インデックスを張ったのに使われない」のは壊れているからとは限らず、
そもそもそのインデックス種別(B-tree)がその条件(部分一致)に向いていないことがある。
条件の形に応じてインデックス種別(B-tree / GIN / GiST / BRIN など)を選ぶ必要がある。

</details>

---

## シナリオ4(上級): 「ページングが後半のページほど遅くなる」

全ユーザー横断の最新TODO一覧に`created_at`の降順インデックスがすでにあります
(前任者が入れてくれていた、という想定です)。

```sql
CREATE INDEX idx_todos_created_at ON todos(created_at);
```

1ページ目は速いのに、ページを進める(`OFFSET`を増やす)ほど遅くなる、という
問い合わせを調査します。

```sql
-- 1ページ目
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, title, created_at FROM todos ORDER BY created_at DESC LIMIT 20 OFFSET 0;

-- 25,000ページ目相当
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, title, created_at FROM todos ORDER BY created_at DESC LIMIT 20 OFFSET 500000;
```

### やってみる

1. 両方の実行時間と`actual rows`を見比べ、何に比例して遅くなっているか特定する
2. インデックスがちゃんと使われている(`Index Scan`である)のに、なぜ遅いのか説明してみる
3. `OFFSET`を使わない書き方(キーセット/カーソルページネーション)に書き換える

<details>
<summary>解答・解説を見る</summary>

#### OFFSET 0 (実測 約0.15ms) vs OFFSET 500000 (実測 約1349ms)

```
-- OFFSET 0
Index Scan Backward using idx_todos_created_at on todos (actual rows=20 loops=1)
Execution Time: 0.152 ms

-- OFFSET 500000
Index Scan Backward using idx_todos_created_at on todos (actual rows=500020 loops=1)
Execution Time: 1349.238 ms
```

インデックスは正しく使われている(`Index Scan`)にもかかわらず、約9,000倍遅くなって
います。理由は`OFFSET`の仕組みそのものにあります。`OFFSET N`は「N行読み飛ばす」という
意味であり、Postgresは**先頭から数えてN+LIMIT件を実際に読んでから**、先頭のN件を
捨てています。ページが深くなるほど読み飛ばす行数が増え、線形に遅くなります。
インデックスを増やしても`OFFSET`自体のコストは減らせません。

#### 対処: キーセット(カーソル)ページネーション

「前のページの最後の行の`created_at`より古い行を20件」という条件に書き換えます。

```sql
SELECT id, title, created_at FROM todos
WHERE created_at < '2026-07-12 07:17:14.78729'  -- 前ページ最後の行のcreated_at
ORDER BY created_at DESC
LIMIT 20;
```

→ ページ番号に関係なく **常に約0.1ms**。`Index Cond`で直接目的の位置から
読み始めるため、読み飛ばしが発生しません。

```
Index Scan Backward using idx_todos_created_at on todos
  Index Cond: (created_at < '2026-07-12 07:17:14.78729'::timestamp without time zone)
Execution Time: 0.109 ms
```

**学び**: 「インデックスがある」=「速い」ではない。`OFFSET`は常にO(N)のコストを
払うアクセスパターンであり、ページが深くなるSNS的なタイムラインや一覧画面では
早い段階でキーセットページネーションに設計すべき。無限スクロールUIとも相性が良い。

</details>

---

## シナリオ5(上級): 「インデックスがあるのにPostgresが使ってくれない」

シナリオ4で`idx_todos_created_at`を作った後、バッチ処理担当から
「『今日作成されたTODO』を数えるバッチが重い」と連絡が来ました。

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM todos WHERE created_at::date = '2026-01-15';
```

### やってみる

1. `idx_todos_created_at`があるのに`Seq Scan`になっている理由を実行計画から読み取る
2. `created_at::date`という書き方の何が問題なのか説明してみる
3. インデックスが使える書き方に直す

<details>
<summary>解答・解説を見る</summary>

#### 初期状態(実測 約333ms)

```
Parallel Seq Scan on todos
  Filter: ((created_at)::date = '2026-01-15'::date)
  Rows Removed by Filter: 3324211
Execution Time: 333.489 ms
```

`idx_todos_created_at`は`created_at`という**生の列の値**に対する索引です。
`created_at::date`は列の値をキャストして別の値を作ってから比較しているため、
Postgresは「この行の`created_at`をキャストしたら条件に合うか」を**行ごとに
計算しないと分からず**、インデックスを辿る方法がありません(= sargable でない)。
これは`WHERE lower(email) = 'x'`や`WHERE created_at + interval '1 day' > now()`
のように、**条件式の左辺(インデックス対象の列)に関数や演算を適用してしまう**
パターン全般に共通する問題です。

#### 対処: 列そのものへの範囲条件に書き換える(sargableにする)

```sql
SELECT count(*) FROM todos
WHERE created_at >= '2026-01-15'::date
  AND created_at <  '2026-01-15'::date + interval '1 day';
```

→ 約333ms → **約6ms**(約55倍)。列を直接比較する範囲条件になったため
`Index Only Scan`が選ばれるようになった。

```
Index Only Scan using idx_todos_created_at on todos
  Index Cond: ((created_at >= '2026-01-15'::date) AND (created_at < '2026-01-16 00:00:00'::timestamp...))
  Heap Fetches: 0
Execution Time: 6.076 ms
```

**学び**: インデックスを使わせたいなら、`WHERE`句の対象列は生のまま、
範囲や等値で比較する形に保つ。どうしても変換が必要なら、変換後の値に対する
**式インデックス**(`CREATE INDEX ... ON todos((created_at::date))`)という
選択肢もあるが、まずは条件式を見直せないか検討するのが先。

</details>

---

## EXPLAIN の読み方 チートシート

- `cost=X..Y`: プランナーの見積もりコスト(開始コスト..総コスト)。実測ではない
- `actual time=X..Y`: 実測開始時間..終了時間(ms)。`ANALYZE` を付けないと出ない
- `rows=N`: 見積もり行数。`actual` 側の `rows` と大きく乖離していたら統計情報(`ANALYZE`)を疑う
- `Rows Removed by Filter`: フィルタで捨てた行数。大きいほど「読みすぎ」のサイン
- `Buffers: shared hit=X read=Y`: `hit`はキャッシュヒット、`read`はディスクI/O。`read`が多い=I/Oバウンド
- `Sort Method: external merge Disk:` / `HashAggregate ... Batches: >1`: `work_mem`不足によるディスクスピル
- `Seq Scan` vs `Index Scan` vs `Bitmap Heap Scan`: テーブル規模と選択性次第でどれが最適かは変わる。`Seq Scan`が常に悪とは限らない(選択性が低いなら全表走査の方が速いこともある)
- `Index Scan` なのに遅い: インデックスが使われていても`OFFSET`による読み飛ばしや、取得行数そのものが多ければ遅くなる。「インデックスを使っている=速い」は早合点
- インデックスが使われない: 種別のミスマッチ(B-treeに部分一致をさせようとしている等)か、`WHERE`句の列側を関数/演算でラップしていてsargableでないケースを疑う

## 便利コマンド

```sql
-- インデックス一覧
\d todos

-- テーブル・インデックスの統計情報
SELECT * FROM pg_stat_user_tables WHERE relname = 'todos';

-- 現在のセッション設定確認
SHOW work_mem;
SHOW shared_buffers;
SHOW random_page_cost;
```
