# PostgreSQL パフォーマンスチューニング実践ラボ

「実務である日突然、クエリが遅くなった」を疑似体験するための練習リポジトリです。
TODOアプリ風のスキーマ(`users` 100,000件 / `todos` 1,000万件)を用意し、
`EXPLAIN (ANALYZE, BUFFERS)` を読みながらボトルネックを特定 → 修正 → 再計測、という
実務のチューニングサイクルを手を動かして体験できます。

設定は意図的にDockerイメージのデフォルトのままにしています(`shared_buffers`,
`work_mem` などをチューニング済みにしてしまうと練習になりません)。

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

## EXPLAIN の読み方 チートシート

- `cost=X..Y`: プランナーの見積もりコスト(開始コスト..総コスト)。実測ではない
- `actual time=X..Y`: 実測開始時間..終了時間(ms)。`ANALYZE` を付けないと出ない
- `rows=N`: 見積もり行数。`actual` 側の `rows` と大きく乖離していたら統計情報(`ANALYZE`)を疑う
- `Rows Removed by Filter`: フィルタで捨てた行数。大きいほど「読みすぎ」のサイン
- `Buffers: shared hit=X read=Y`: `hit`はキャッシュヒット、`read`はディスクI/O。`read`が多い=I/Oバウンド
- `Sort Method: external merge Disk:` / `HashAggregate ... Batches: >1`: `work_mem`不足によるディスクスピル
- `Seq Scan` vs `Index Scan` vs `Bitmap Heap Scan`: テーブル規模と選択性次第でどれが最適かは変わる。`Seq Scan`が常に悪とは限らない(選択性が低いなら全表走査の方が速いこともある)

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
