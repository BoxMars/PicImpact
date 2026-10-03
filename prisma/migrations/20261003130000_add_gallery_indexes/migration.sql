-- 画廊热路径缺少可用索引（实测自 spec §4 R11）。
--
-- 背景：首页与每个相册页都要跑「列表 + 总数」两条查询，而它们都带
-- `image.del = 0 AND image.show = 0`（首页再加 show_on_mainpage = 0），
-- 并按 `image.sort DESC, ...` 排序；总数查询用 `SELECT DISTINCT ON (image.id)`。
-- 但 images 表上只有 exif->>'model' / exif->>'lens_model' 两个表达式索引，
-- 于是每次都全表扫描 + 全排序。虽然目前只有几十行、绝对耗时不大，
-- 但随着图库增长这条成本是线性上升的，且排序键
-- `COALESCE(TO_TIMESTAMP(COALESCE(exif->>'data_time', ...)))` 是派生表达式、
-- 无法索引，因此这里为可索引的部分（可见性 + sort/created_at）建部分索引。
--
-- 另外 images_albums_relation 的主键是 ("imageId","album_value")，按 album_value
-- 单独查询无法命中，需要一条以 album_value 打头的索引。
--
-- 注：非 CONCURRENTLY —— Prisma migrate 在事务中执行。当前表规模很小（数十行），
-- 加锁时间可忽略。

-- 按相册查关联：让 album_value 打头的查询能走索引
CREATE INDEX IF NOT EXISTS "images_albums_relation_album_value_imageId_idx"
  ON "images_albums_relation" ("album_value", "imageId");

-- 画廊列表的排序：仅覆盖可见行，减少索引体积
CREATE INDEX IF NOT EXISTS "images_visible_sort_created_idx"
  ON "images" ("sort" DESC, "created_at" DESC)
  WHERE "del" = 0 AND "show" = 0;

-- 标签页用 `labels::jsonb @>` 做包含查询。
-- 注意：`labels` 列的真实类型是 `json`（不是 jsonb），而 json 没有 GIN 的默认操作符类，
-- 直接 `USING GIN ("labels")` 会报 42704。这里对**查询里实际使用的那个转换**建表达式索引
-- `((labels)::jsonb)` —— 已验证 Postgres 接受这个表达式为 immutable。
CREATE INDEX IF NOT EXISTS "images_labels_gin_idx"
  ON "images" USING GIN (((labels)::jsonb));
