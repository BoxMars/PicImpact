# 计划：从 Vercel + Supabase 迁移到 Cloudflare Workers + D1

状态：调研中（未开始实施）
创建：2026-10-07
约束：**本计划相关工作一律不 push**（用户明确要求）

---

## 0. 为什么要迁（实测数据，不是感觉）

2026-10-07 实测线上 `felina.boxz.dev`：

| 请求 | TTFB | 备注 |
|---|---|---|
| `/admin`（一个 307 跳转） | 1.14s | 管理页全是动态请求，所以最卡 |
| `/api/public/v1/config`（已预热） | 1.05s | 链路地板 |
| `/api/public/v1/images?page=1`（冷启） | 5.03s | |
| 一张预览图 | 1.19s | |
| 8 KB 静态 SVG | 0.90s | |

当前链路（每一跳都是实测出来的）：

```
用户（中国）→ Cloudflare 边缘（新加坡 sin1 / 香港 hkg1）→ Vercel 函数（美东 iad1）
            → Supabase PostgreSQL（东京 ap-northeast-1）
```

证据：
- 响应头 `x-vercel-id: sin1::iad1::…`，**连续 5 次探测函数区域恒为 iad1**（边缘从 sin1 变到 hkg1，函数不变）
- 已提交 `vercel.json` 指定 `regions: ["hnd1"]` —— **免费版忽略**，实验结论：必须 Pro
- `DATABASE_URL` 主机 `aws-1-ap-northeast-1.pooler.supabase.com` = 东京

所以每次动态请求要在**三个大洲之间往返两次**。Functions 与数据库同区即可把 1.05s 降到几百毫秒；
Workers 跑在边缘（香港/新加坡）且紧邻东京数据库，理论上更优。

## 1. 调研发现（含来源，标明置信度）

### 1.1 已确认

- **Prisma 有官方 D1 适配器**：Cloudflare 官方教程《Query D1 using Prisma ORM》
  https://developers.cloudflare.com/d1/tutorials/d1-and-prisma-orm/
  npm 包 `@prisma/adapter-d1` **确实存在**（直接查 npm registry 核实，不依赖二手描述）：
  包名 `@prisma/adapter-d1`，最新 `7.10.0`，稳定版里有 `6.19.3` 这一档；
  依赖为 `ky` / `@cloudflare/workers-types` / `@prisma/driver-adapter-utils`（与 Workers 定位一致）。
  → 数据库层不必换 ORM，但 schema 要按 SQLite 改写（见 1.3）。

  ✅ **版本缺口：不存在**（这里更正我上一轮的判断 —— 当时我说"最早可见 6.19.3、6.4.1 可能太旧"，
  那是**错的**）。完整拉取版本谱系后：`@prisma/adapter-d1` 的 6.x 稳定版从 **6.0.0** 就有
  （发布于 2024-11-28），7.x 从 7.0.0 起。适配器版本与 Prisma 主版本是**一一对应**的，
  所以本项目用 **6.4.1 可以配 `@prisma/adapter-d1@6.4.x`**，**不需要为了用适配器升级 Prisma**。

  → P0-3 的范围因此缩小为「跑通最小例程 + 改 SQLite 语法」，不包含 Prisma 大版本升级。
    上一次的误判来自只看 registry 返回里最后 8 个版本；教训是**版本谱系必须完整拉取再下结论**。
- **Next.js on Workers 有官方路径**：`@opennextjs/cloudflare`
  https://developers.cloudflare.com/workers/framework-guides/web-apps/opennext/
  包本身**活跃维护**（查 npm registry：最新 1.20.9，发布于 2026-10-06，132 个稳定版）。
  它的 peerDependencies 划出硬门槛：`next >=15.5.27 <16 || >=16.3.8`、`wrangler ^4.125.0`、`rclone.js ^0.6.6`。

  ⚠️ **本项目不满足该门槛，需要升级依赖**（逐条核对过版本号）：

  | 依赖 | 本项目 | OpenNext 要求 | 结论 |
  |---|---|---|---|
  | next | **16.1.6** | >=15.5.27 <16 或 **>=16.3.8** | ✗ **16.1.6 两个区间都不在**，需升到 16.3.8+ |
  | wrangler | **未安装** | ^4.125.0 | ✗ 需新增 |
  | @prisma/client / prisma | **6.4.1** | 见 1.1 的 D1 适配器说明 | ✗ 需升级以配合 `@prisma/adapter-d1` |

  也就是说：**迁移前要先做一轮依赖升级**（Next 16.1.6 → 16.3.8+、Prisma 6.4.1 → 支持 D1 适配器的版本、新增 wrangler）。
  这一轮升级本身要单独验证 —— 尤其本项目用了 Next 16 的 server actions 与 `revalidateTag`，
  升级后要回归首页 ISR 与上传流程。
- **曾直接命中本项目的 catch-all bug —— 已修复**（2026-10-07 查证）：

  opennextjs-cloudflare issue #942「Cloudflare build crashes on catch-all API route
  `/api/auth/[...better-auth]` due to invalid regex」
  https://github.com/opennextjs/opennextjs-cloudflare/issues/942

  本项目正是 `app/api/auth/[...all]/route.ts`（better-auth 官方 Next 处理器），形状完全一致。

  **查证结论：已关闭且已完成修复**。证据链（三处互相印证，不是推断）：
  1. 页面载荷里 `"state":"CLOSED"` 且 `"stateReason":"COMPLETED"`；
  2. 页面上明确写着 `fixed in @opennextjs/cloudflare@1.10.1`（附 PR 链接）；
  3. 有用户回复确认修复后错误消失（"I can confirm the error is gone now"）。

  而本项目要用的版本是 **1.20.9**（当前 latest，2026-10-06 发布），**远高于修复版本 1.10.1** ——
  所以这个 bug 在目标版本上不构成阻碍。**P0-2 由"最大不确定性"降级为"已消除"。**

  另一个相关 issue #345「getCloudflareContext gives error on catch-all routes」仍**未查证**，
  留待 spike 时一并确认（若命中，绕过方式是用 `cloudflareContext` 的异步 API 而不是同步取值）。

  取证方法记一笔：GitHub API 未认证调用按 IP 限流（60/小时，实测遇到 403 与配额 0），
  网页版用 `web_fetch` 会被导航淹没；**可行做法是 `curl` 抓 HTML 后从页面内嵌 JSON 里 grep
  `"state"` / `"stateReason"`**（本次即用此法拿到结论）。
- **图片处理有官方 binding，而且免费额度就够用**（读官方 Pricing 文档原文确认）：
  https://developers.cloudflare.com/images/optimization/binding/ 与 https://developers.cloudflare.com/images/pricing/

  关键事实：
  * **默认就在 Images Free 计划上**，而 Free **包含 transformations**（缩放）—— 用于优化**存储在 Images 之外**
    （例如 R2）的图片。免费额度：**每月 5,000 次 unique transformation**。
  * 超出后：**已缓存的缩放宽照常服务**，新的返回错误码 `9422`（可用 `onerror` 回退到原图），
    而且 —— **Free 计划超限不收费**（只是新变换失败）。
  * 计费口径是**每月去重的 unique transformation**（同一张图同一组参数在一个月内只算一次），
    所以日常重复访问不会线性累计。
  * R2 侧免费额度：10 GB 存储、100 万次 Class A、1000 万次 Class B（见该页 Example #2 的脚注）。

  → **对本站完全够**：图库只有 56 张，按每张 2-3 个尺寸算，一个月约 150-200 次 unique transformation，
    离 5,000 差两个数量级。**结论：sharp 可以用 Images binding 替代，且不需要买 Images 付费版。**
  → 注意：上传时**生成**预览图也可以走 binding（`.input().transform().output()`），每次上传只消耗个位数变换。
  → 已有预览图（此前由 sharp 生成并存放在资源站）不需要重做，随数据迁移搬到 R2 即可。

### 1.2 已确认的关键限制（2026-10-07 读官方 Limits 文档原文）

来源：https://developers.cloudflare.com/workers/platform/limits/
（技巧：Cloudflare 文档加 `/index.md` 可拿到干净正文，避免抓取被导航淹没。）

| 限制项 | Workers Free | Workers Paid |
|---|---|---|
| **每次 HTTP 请求的 CPU 时间** | **10 ms** | 5 分钟（默认 30 秒） |
| 请求数 | 10 万/天 | 无限制 |
| 内存/isolate | 128 MB | 128 MB |
| 子请求/次 | 50 | 10,000 |
| Worker 体积（未压缩） | 64 MiB | 64 MiB |
| 启动时间 | 1 秒 | 1 秒 |
| 静态资源文件数 | 20,000 | 100,000 |

**结论：免费版放不下这个站** ✓ —— 官方文档在同一页写明：

> Heavier workloads that handle **authentication, server-side rendering**, or parse large payloads
> typically use **10-20 ms**.

本项目的负载正是「认证（better-auth）+ SSR（Next.js）」→ 落在 10-20 ms，而免费版只有 10 ms。
按官方错误码，超限会返回 1102「Worker exceeded resource limits」。

**但经济学因此反转**：Workers **付费只要 5 美元/月**，而 Vercel Pro 是 20 美元。
也就是说「更快 + 更便宜」是成立的，前提是用付费版 Workers。

要留意的两个次生限制：
- **Worker 启动时间 1 秒**：Prisma Client 在全局作用域初始化是社区公认的坑，要在 spike 里量。
- **子请求 50/次（免费）**：Workers Static Assets 不算子请求，但 API + D1 调用算；付费版 10,000 无忧。

- [ ] 仍待核实：**D1 的容量/QPS/跨区延迟**（https://developers.cloudflare.com/d1/platform/limits/）
- [ ] 仍待核实：**Images binding 的计费**（https://developers.cloudflare.com/images/pricing/）
- [ ] **两个 Cloudflare 账号怎么配合**。已知：`boxz.dev` 在**免费账号**（有免费 Worker），
      另有**付费账号**但**没有托管 boxz.dev**。
      **结论（已由官方文档确认）**：**不要动那个付费账号，把托管 boxz.dev 的免费账号升级为 Workers Paid（5 美元/月）**。

      依据：Custom Domains 文档的 Caution 原文（https://developers.cloudflare.com/workers/configuration/routing/custom-domains/）：

      > You cannot create a Custom Domain on a hostname with an existing CNAME DNS record
      > **or on a zone you do not own**.

      即 Worker 的自定义域**必须挂在同账号的 zone 上** → 没有托管 boxz.dev 的付费账号**无法**把
      felina.boxz.dev 指过去。所以只有两条路：
      (a) **把持有域名的账号升级为 Workers Paid** —— 不动 DNS、不改 NS，风险最小（推荐）；
      (b) 把 zone 迁到付费账号 —— 要改 NS、动全部 DNS 记录，风险与工作量都大得多。

      顺带确认：`felina.boxz.dev` 与 `felina-asset.boxz.dev` 都是**一级子域**，正好在 Universal SSL
      覆盖范围内；Custom Domain 会自动建 DNS 记录并签发证书，不需要额外订阅 Advanced Certificate Manager。
- [ ] **D1 的实际能力边界**：单库容量、读写 QPS、并发写、跨区读延迟（D1 是单主库 + 读副本）。
      图库只有几十张图、访问量小，容量不是问题，但**写放大与冷读延迟**要看清楚。
- [ ] **better-auth 在 Workers 上**：依赖的 crypto / 存储是否都能跑；会话表放 D1 的适配。
- [ ] **R2** 存原图与预览图（替换 `felina-asset.boxz.dev` 当前的对象存储），以及自定义域。

### 1.3 已知的硬骨头（Postgres → SQLite）—— 已做代码级盘点

迁移不是"换个连接串"。下面是**从代码里数出来的**清单（不是泛泛而谈）：

**schema 层（`prisma/schema.prisma`）**

| 项 | 数量 | 处理 |
|---|---|---|
| `@db.Timestamp` | 19 | 去掉标注（SQLite 无原生类型属性） |
| `@db.Text` | 13 | 同上 |
| `@db.VarChar` | 10 | 同上 |
| `@db.SmallInt` | 10 | 同上 |
| `@db.Json` | 2 | 同上（`exif` / `labels` 两个字段） |
| 枚举 `enum` | **0** | 无需迁移（好消息） |
| `@default(now())` | 3 | SQLite 可用 `CURRENT_TIMESTAMP`，需确认 Prisma 生成结果 |

合计 **54 处类型标注**要去掉，另有 2 个 JSON 字段（`exif` 用于相机/镜头等 EXIF，`labels` 用于标签）
在 SQLite 里以 TEXT 存储，查询要走 `json_extract`。

**查询层（`server/**`）**

| 项 | 数量 | 风险 |
|---|---|---|
| `$queryRaw` / `$executeRaw` 调用点 | **23** | ✗ 最大的一块，逐个都要审 |
| 其中 `SELECT DISTINCT ON (...)` | **4**（均在 `server/db/query/images.ts`） | ✗ **SQLite 不支持**，必须改写为窗口函数或子查询 |
| JSON 操作符 `->>` | **确实在用**（直接证据：`server/db/query/images.ts:12` 的 `image.exif->>'data_time'`、`:76` 的 `image.exif->>'model'`、`:338` 的 `labels::jsonb`） | 改 `json_extract` |

补充实测（这些都是 **SQLite 不存在**的 Postgres 专有写法，逐个计数）：

| Postgres 专有写法 | 处数 | 说明 |
|---|---|---|
| `TO_TIMESTAMP(...)` | 4 | 首页/相册的**排序**表达式，把 EXIF 的 `YYYY:MM:DD HH24:MI:SS` 字符串转时间 |
| `jsonb_array_elements_text()` | 1 | 取标签集合（`server/db/query/images.ts:338`） |
| `SELECT DISTINCT ON (...)` | 5 | 列表查询 |
| `::jsonb` / `::json` 强制转换 | 4 + 4 | 同上 |

⚠️ **排序是最麻烦的一处**：EXIF 的时间字符串是 `2026:10:05 12:00:00` 这种**非 ISO** 格式，
SQLite 的 `strftime` 不能直接解析；改写要么在 SQL 里做字符串整形
（`substr` + `replace` 把 `:` 换成 `-`），要么**新增一个归一化的拍摄时间列**并在写入时维护。
schema 里目前**没有**这样的列（已确认），而仓库里存在 `scripts/migrate/backfill-exif-capture-time.ts`，
说明历史上考虑过归一化 —— spike 时要决定走哪条路（这是**设计决策**，不只是语法替换）。

> 过程记录：我一度用循环统计 `->>` 得到 0 处，与「直接打印出 `exif->>'data_time'`」矛盾 ——
> 是我的循环匹配写错了，不是代码里没有。**以直接证据为准**，没有把那个 0 写进结论。

**迁移目录**：`prisma/migrations/*` 全是 Postgres SQL，迁到 D1 需要**重做一套 SQLite 迁移**（不能复用）。

#### 已验证的改写之一：列表排序（最麻烦的一处，已通过交叉验证 ✅）

原写法（Postgres，用 `TO_TIMESTAMP` 解析 EXIF 时间串）：

```sql
COALESCE(TO_TIMESTAMP(COALESCE(image.exif->>'data_time', image.exif->>'date_time'),
                      'YYYY:MM:DD HH24:MI:SS'), '1970-01-01 00:00:00') DESC,
image.created_at DESC, image.updated_at DESC
```

**改写（SQLite）—— 不需要解析日期**：

```sql
COALESCE(json_extract(image.exif, '$.data_time'),
         json_extract(image.exif, '$.date_time'),
         '1970:01:01 00:00:00') DESC,
image.created_at DESC, image.updated_at DESC
```

**为什么可以不解析**：先查了**真实数据**（种子里的 56 张图）—— `data_time` 56/56 有值、`date_time` 25/56，
时间串形态 **55 张都是 `YYYY:MM:DD HH:MM:SS`**（定宽、零填充、大端）。这种格式的**字典序就等于时间序**，
所以直接用 `json_extract` 取字符串排序即可，比原来的 `TO_TIMESTAMP(...)` 更简单、且没有解析失败的风险。
（`'1970:01:01 00:00:00'` 兜底值同样按字典序落在最后。）

**验证方式（可复用到其余 22 个调用点）**：
1. 用上一节的 SQLite 空库建表；
2. 灌入**真实的 56 条**（id / exif / createdAt 取自种子文件，不是编造数据）；
3. 用改写后的 SQL 在 SQLite 里排一遍；
4. 用 Python **独立**按同一规则排一遍；
5. 逐个比对 —— 本次结果：**两者完全一致**（前 5 个 id 逐一相同）。

> 这种「换一种实现独立算一遍再比对」的验证，比"看起来对"可靠得多；
> 23 个原始 SQL 调用点都应按此法逐个验证，而不是改完就信。

#### 已验证的改写之二：全部标签（`server/db/query/images.ts` 的 `fetchAllTags`）

原写法（Postgres，集合返回函数 + 类型兜底）：

```sql
SELECT DISTINCT tag
FROM "public"."images" AS image,
     jsonb_array_elements_text((image.labels)::jsonb) AS tag
WHERE image.del = 0 AND image.show = 0
  AND image.labels IS NOT NULL
  AND jsonb_typeof((image.labels)::jsonb) = 'array'
ORDER BY tag
```

**改写（SQLite）**：

```sql
SELECT DISTINCT je.value AS tag
FROM images AS image,
     json_each(
       CASE WHEN json_valid(image.labels)
            THEN (CASE WHEN json_type(image.labels) = 'array' THEN image.labels ELSE '[]' END)
            ELSE '[]' END
     ) AS je
WHERE image.del = 0 AND image.show = 0 AND image.labels IS NOT NULL
ORDER BY tag
```

对应关系：`jsonb_array_elements_text(x)` → `json_each(x)` 取其 `.value`；
`jsonb_typeof(x) = 'array'` → `json_type(x) = 'array'`；`(x)::jsonb` 转换去掉（SQLite 的 JSON 函数直接吃 TEXT）。

**为什么用嵌套的 `CASE` 而不是 `AND` 串联条件**：SQLite 的 `json_each` 遇到**非法 JSON 会直接报错**
（比 Postgres 更危险），而 SQL 里 `AND` 的求值顺序**没有保证**，`json_valid(x) AND json_type(x)='array'`
仍可能先算 `json_type` 而炸掉。嵌套 `CASE` 是**惰性**的，能确保先验合法性再取类型，
非法值退化为 `'[]'`（即"不贡献标签"），与原 Postgres 版本 `jsonb_typeof` 兜底的**意图一致**。

**验证（这次先踩了一个坑，见下）**：入库 63 行 = 56 条真实数据（实测标签全是 `[]`）+ 3 条合成标签
（`["猫","日常"]` / `["猫","风景"]` / `["风景"]`）+ 4 条刻意脏数据（非法 JSON / 对象 / NULL / 空数组）。

结果：SQLite 得 `['日常','猫','风景']`，Python 独立计算完全相同；**去重正确**（`猫` 出现在两行里只输出一次）；
**4 条脏数据既没让查询报错、也没产生任何标签**。

> ⚠️ **差点交出一个"空的 ✓"**：第一次跑这个验证时，两边都返回 **0 个标签**，"两者一致 ✓" 只是 `0 == 0`，
> **什么也没证明**。原因是真实的 56 条数据 `labels` 全是 `[]`（实测：56/56 都是空数组）。
> 发现后补了 3 条合成标签重跑，才得到**非空**的验证结果。
> **教训**：比对类断言必须**先确认两侧都有数据**，否则"一致"可能只是"两边都空"。
> 这一条适用于其余 22 个调用点 —— 验证脚本要先打印样本量，再断言相等。

#### 已验证的改写之三：5 处 `SELECT DISTINCT ON (image.id)`（全部只有 id，改写反而最简单）

**先逐个打印了 5 处各自 SELECT 了什么**（这一步是决定改写方式的关键，不能套模板）：

```
server/db/query/images.ts:124 / 149 / 280 / 300 / 437
  全都是： SELECT DISTINCT ON (image.id)  →  image.id     ← 只选 id
```

因为它们**只投影 id**，"重复行里留哪一行"这件事根本不涉及 → `DISTINCT ON (id)` 与 `DISTINCT id` **完全等价**，
**不需要窗口函数**（我此前以为这是"最后一类结构性问题"，说重了）。这些查询的用途都是**为计数去重**
（图与相册是多对多，join 会放大行数）。

**改写（SQLite）**：

```sql
-- 形式一（保持原有子查询结构，改动最小）
SELECT COALESCE(COUNT(1),0) AS total
FROM (SELECT DISTINCT image.id FROM ... ) AS unique_images;

-- 形式二（更直接）
SELECT COUNT(DISTINCT image.id) FROM ... ;
```

**验证（同样先踩了空验证，见下）**：造 4 张图、6 条相册关联（i1 与 i4 各挂 2 个相册），
在**不加相册过滤**（即"无相册"分支的形状）下：

| 口径 | 结果 |
|---|---|
| 不去重的原始行数 | **6**（被关联放大） |
| 实际图片数 | **4** |
| 改写① `SELECT DISTINCT id` 子查询 | **4** ✓ |
| 改写② `COUNT(DISTINCT image.id)` | **4** ✓ |
| 去重后的 id 列表 | `['i1','i2','i3','i4']` 恰好 4 个、无重复 ✓ |

> ⚠️ **同一个空验证陷阱，两轮里踩了两次**：这一处第一次跑时我加了 `album_value = 'albA'` 过滤，
> 于是每张图对该相册只出现一次 → 原始 3 行、去重后仍是 3 行，**`DISTINCT` 根本没被考验**。
> 去掉相册过滤后才得到 6 → 4 的**有效**验证。
> **强化后的规矩**：验证脚本必须打印「输入量 / 去重量 / 期望量」三个数字并断言**它们之间存在差异**，
> 而不是只断言两个结果相等 —— 相等可能是双方都为空、或去重根本没发生。

#### 已验证的改写之四：JSON 包含运算符 `@>`（2 处，标签筛选）

新发现的两处（`server/db/query/images.ts:422` 与 `:454`）：

```sql
image.labels::jsonb @> ${JSON.stringify([tag])}::jsonb
```

`@>`（JSON 包含）是 **Postgres 专有**，SQLite **没有**对应运算符。SQLite 的标准替代是
`EXISTS` + `json_each`：

```sql
EXISTS (
  SELECT 1 FROM json_each(
    CASE WHEN json_valid(image.labels)
         THEN (CASE WHEN json_type(image.labels) = 'array' THEN image.labels ELSE '[]' END)
         ELSE '[]' END) AS je
  WHERE je.value = ${tag}
)
```

同样用**嵌套 CASE** 而不是 `AND` 串联 —— 理由与标签查询一致：SQLite 的 `json_each` 遇到非法 JSON 直接报错，
而 `AND` 的求值顺序没有保证。

**验证**（8 行输入：正常标签 / 空数组 / **重复标签** / NULL / 非法 JSON / 对象）：

| 查询 | SQLite 结果 | Python 期望 | 输入/命中/期望 |
|---|---|---|---|
| 标签「猫」 | `['a','b','e']` | `['a','b','e']` ✓ | 8 / 3 / 3 |
| 标签「风景」 | `['b','c']` | `['b','c']` ✓ | 8 / 2 / 2 |
| 标签「狗」 | `[]` | `[]` ✓ | 8 / 0 / 0 |

* 重复标签（某行 `["猫","猫"]`）只命中**一次** → `EXISTS` 语义正确 ✓
* 非法 JSON 与对象**既没报错也没命中** → 兜底逻辑正确 ✓
* 「狗」这个**空结果**是有意义的反例：前两个查询都非空，说明数据造对了、查询也确实在工作，
  不是"双方都为空"式的假验证 ✓

#### 该类剩余清单（本轮同步盘点）

| 项 | 处数 | 状态 |
|---|---|---|
| `TO_TIMESTAMP` | 3 处代码 + 1 处注释 | ✓ 已改写并验证（就是排序常量那一组） |
| `jsonb_array_elements_text` | 1 | ✓ 已改写并验证 |
| `jsonb_typeof` | 2（1 代码 + 1 注释） | ✓ 随标签查询一并处理 |
| `SELECT DISTINCT ON` | 5 | ✓ 已改写并验证 |
| `@>` 包含运算符 | 2 | ✓ 本轮改写并验证 |
| `NOW()` | 3 | ✓ 已定位并给出改写（见下），陷阱已实测复现 |
| `json_array_elements` | 1 | ✅ **只在注释里**（不是代码），无需处理 |
| `COALESCE` | 38 | ✅ **两边通用**，无需改动 |

> 盘点中一个值得记的好消息：38 处 `COALESCE` 全部**跨库通用** —— 原始 SQL 里大部分内容是可直接移植的，
> 真正需要改的是**少量专有语法**，而不是整段重写。

#### 已验证的改写之五：`NOW()` —— 而且它藏着一个**格式陷阱**

3 处全在 `server/db/operate/configs.ts`，形态都是 `UPDATE ... SET updated_at = NOW()`。

**不能简单换成 `CURRENT_TIMESTAMP`**。原因是 SQLite 里 `DateTime` 的**实际存储形态**取决于写入方：

| 写入方 | 产出 |
|---|---|
| Prisma（应用常规路径） | `2026-10-07T01:00:00.000Z` —— ISO-8601，**T** 分隔、带毫秒与 Z |
| SQLite `CURRENT_TIMESTAMP` | `2026-10-07 23:00:00` —— **空格**分隔、无毫秒 |
| SQLite `strftime('%Y-%m-%dT%H:%M:%fZ','now')` | `2026-10-07T01:00:00.000Z` —— **与 Prisma 一致** ✓ |

同一个列里一旦混入两种格式，**字符串排序就会错**：`'T'`(0x54) > `' '`(0x20)，所以在**日期相同**时，
格式会压过时间。

**实测复现**（同一天的两个时刻，按 `updated_at` 倒序，本意是"更晚的在前"）：

| 写入的行 | 值 |
|---|---|
| ISO 格式（01:00） | `2026-10-07T01:00:00.000Z` |
| 空格格式（**23:00**） | `2026-10-07 23:00:00` |

排序结果：**01:00 排在 23:00 前面** ✗ —— 排序错误。统一成 ISO 格式后（两行都用 `strftime` 形态），
23:00 正确排在前 ✓。

**结论**：`NOW()` 应改写为 `strftime('%Y-%m-%dT%H:%M:%fZ','now')`，保持与 Prisma 一致的格式，
而不是用 `CURRENT_TIMESTAMP`。

> ⚠️ **第一次的演示没有证明出问题**：我最初构造的三行里，时间先后恰好与字符串序一致，
> 「陷阱」其实没被触发 —— 如果就那么写进结论，会是一条**看起来有数据、实际不成立**的证据。
> 换成"同一天、格式不同"的用例才真正复现。**教训**：要证明一个排序/格式类 bug，
> 必须构造**让两个因素冲突**的用例（这里就是"日期相同、时间不同"），
> 否则数据再多也证明不了。

→ 结论：这一段是**有明确工作量的工程**（23 个原始 SQL 调用点 + 54 处标注 + 一套新迁移），
  但边界清楚、可逐项勾选，没有未知黑盒。

## 1.5 架构决定（2026-10-07 用户明确）：**后续不再使用 Vercel 与 Supabase**

这不是"优化公开页面的延迟"，而是**整体迁走**。它把范围钉死为：

| 部分 | 迁到 | 说明 |
|---|---|---|
| 公开页面（首页/相册/标签/地图/详情/隐私/条款/rss） | 同一个 Worker | 优先按**静态/ISR** 提供；命中静态资源时不消耗函数 CPU |
| 后台（9 页）+ 登录/注册 + 上传 + 全部 API | 同一个 Worker | 这部分**必须动态**，所以免费版 10ms 一定不够 |
| 数据库 | **D1（SQLite）** | 即 1.3 已验证的那套改写；**Supabase 退出** |
| 图片存储与分发 | **R2** + 自定义域 | 替换现有 `felina-asset.boxz.dev` 的对象存储 |
| 图片缩放/预览图生成 | **Images binding** | 替代 **sharp**（1.1 已确认免费额度够用） |
| 鉴权 | **better-auth + D1** | 表结构已在 SQLite 下**建出来验证过**（10 张表含 user/session/account/passkey…） |
| 域名 | 仍 `boxz.dev` | 必须升级**持有该 zone 的那个账号**为 Workers Paid（Custom Domain 必须同账号，见 1.2） |

**因此的结论**：
1. **必须要 Workers Paid（5 美元/月）** —— 后台/鉴权/上传放不进 10ms。
   但这仍是 Vercel Pro（20 美元）的四分之一，且比现在更快。
2. **"不用 SSR" 依然值得做，但它是这个 Worker 内部的优化，而不是替代方案**：
   公开页面按静态/ISR 提供（命中静态资源不消耗 CPU、也不经过函数冷启动），
   后台保持动态。两者**同一个 Worker、同一套代码**，由 OpenNext 一并处理。
3. **前面 11 轮的调研全部回到主线**：CPU 限制、账号归属、依赖门槛、D1 的 schema 与 SQL 改写，
   都是这次迁移的**必需前置**，不是被绕过的备选。
4. **迁移完成后的下线清单**（别忘了）：
   - Vercel 项目与 `vercel.json`（含本仓库里那条 `regions: ["hnd1"]` 实验配置）
   - Supabase 项目（先确认数据已完整搬入 D1 并校验行数）
   - `DATABASE_URL` / `DIRECT_URL` 等 Supabase 连接串从环境变量里移除
   - 部署流水线改为 `wrangler deploy`（GitHub 集成或 Actions）

## 2. 分阶段计划

### Phase 0 —— 可行性 spike（不碰主站）
目标：在**不影响线上**的前提下，回答 1.2 里的四个问题。
- [x] P0-1 核实 Workers 免费/付费 CPU 上限与计费 —— **已完成**（见 1.2：免费 10ms 不够 SSR，付费 5 分钟）
- [x] P0-2 issue #942（catch-all 路由让 CF 构建崩）**已查证为已修复** —— 于 1.10.1 修复，本项目用 1.20.9。
      证据见 1.1（state=CLOSED / stateReason=COMPLETED / 页面原文 fixed in @1.10.1 / 用户确认）。
      剩余动作：issue #345（getCloudflareContext 在 catch-all 路由上的报错）留到 spike 时确认。
- [x] P0-3 schema 层实证 —— **已完成，结果好于预期**。做法：零侵入（不装任何依赖、不动仓库），
      把 `prisma/schema.prisma` 复制到 `/tmp/d1spike`，只改两处后用**仓库自带的 Prisma 6.4.1** 验证并建库：

      1. `provider = "postgresql"` → `"sqlite"`，`url = env("DATABASE_URL")` → 本地文件
      2. 去掉 **54 处 `@db.*` 原生类型标注**（VarChar/Text/SmallInt/Timestamp/Json）
      3. 去掉 **1 处 `directUrl = env("DIRECT_URL")`** —— SQLite/D1 没有池化/直连之分

      结果：
      * `prisma validate` → `The schema at … is valid 🚀`
      * `prisma db push` → `SQLite database test.db created` / `Your database is now in sync … Done in 13ms`
      * 建出 **10 张表**：`images` / `configs` / `albums` / `images_albums_relation`，
        以及 better-auth 的 `user` / `session` / `account` / `verification` / `passkey` / `two_factor`
      * `images` 表列类型符合预期；**`exif` / `labels` 在 SQLite 里是 `JSONB`**（Prisma 的 SQLite 连接器
        **接受 `Json` 类型**，存为 TEXT —— 此前担心的"JSON 字段要改结构"**不成立**）

      **结论**：schema 迁移是**机械改动**（54 处标注 + 1 行 directUrl），没有结构性阻碍；
      **better-auth 的表也能原样建出来**，这同时降低了第 5 项（鉴权兼容性）的风险。
      数据库这块真正的工程量集中在**原始 SQL**（23 个 `$queryRaw`/`$executeRaw` 调用点，见 1.3），不在 schema。

      ⚠️ 仍需实证的剩余部分：`@prisma/adapter-d1` 在**真实 D1 binding** 上的一读一写
      （本次验的是 schema 与 DDL，没有触及 adapter 与 D1 运行时）。
- [x] P0-3b **Postgres 专有用法清单**（已完成，见 1.3 —— 把"要改 SQLite"变成可勾选列表）
- [x] P0-4 Images binding 能替代 sharp 的预览图管线，**计费已查清**（见 1.1：Free 含变换、5,000 次/月、
      超限不收费只报 9422；本站约 150-200 次/月）—— 剩一步：实测缩放一张真图
- [x] P0-5 两个账号的域名/Worker 归属验证 —— **已完成**（见 1.2 结论：Custom Domain 必须与 zone 同账号，
      所以升级持有域名的账号；付费账号不参与）
- 产出：一份 spike 结论 + 明确 go / no-go

### Phase 1 —— 数据与 schema
- [ ] P1-1 把 `schema.prisma` 改写成 SQLite 兼容版（保留 Postgres 版以便回滚，用分支隔离）
- [ ] P1-2 重写迁移 SQL；把 DISTINCT ON 与 JSON 索引改写成 SQLite 写法
- [ ] P1-3 从 Supabase 导出数据、导入 D1，并**逐表比对行数与抽样内容**
- [ ] P1-4 查询层改造：`server/db/**` 里所有 Postgres 专有 SQL

### Phase 2 —— 运行时与图片
- [ ] P2-1 better-auth 会话改造（D1 存储 + Workers 兼容）
- [ ] P2-2 sharp → Images binding（或 WASM 方案），改动上传与预览图生成
- [ ] P2-3 R2 接管图片存储与分发（含自定义域）
- [ ] P2-4 server actions 在 Workers 上的逐一验证

### Phase 3 —— 切换
- [ ] P3-1 用 workers.dev 子域跑通全站，与线上并行比对
- [ ] P3-2 域名切换（含 DNS/TLS、以及**回滚预案**：保留 Vercel 部署随时切回）
- [ ] P3-3 上线后复测本文档第 0 节那张表，给出前后对比

## 3. 风险与退出策略

- **最大风险已消除**：免费版 10ms CPU 确实放不下（官方文档确认），但 **Workers Paid 只要 5 美元/月**
  且给到 5 分钟 CPU —— 比 Vercel Pro（20 美元）更便宜，同时延迟更低（边缘在香港/新加坡 + 数据库在东京）。
  代价是需要**把持有域名的那张卡从免费升到付费**。
- **次大风险**：opennext + better-auth catch-all 的已知 bug 未修 → 需要改鉴权实现，工作量不可控。
- **退出策略**：任一 Phase 的验证不通过即停下汇报，不硬推。**主站始终保持 Vercel 在线**，
  只有 Phase 3 才切流量，且保留一键回滚。

## 4. 与本次会话其它工作的边界

- 站点当前的「新上传图片默认显示」修复（`a4b8945`）与 App Store 横幅回退（`8b53754`）**已推送**，与本计划无关。
- 本计划的所有产物（含本文件）**不 push** —— 等 Phase 0 结论出来、你确认 go 之后再定。
