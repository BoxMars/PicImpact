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

  ⚠️ **版本缺口（需要升级 Prisma）**：本项目用的是 **Prisma 6.4.1**，而 registry 上稳定版里能看到的最早
  6.x 适配器是 **6.19.3** → 现在的 6.4.1 很可能**早于适配器引入**。所以 P0-3 不只是"跑个例程"，
  还包含一次 **Prisma 升级**（先升到适配器支持的 6.x，或直接上 7.x），升级本身要单独验证
  （Prisma 大版本升级可能带 schema/客户端 API 变化，本项目 `server/db/**` 用量不小）。
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
- **已知 bug 直接命中本项目**：opennextjs-cloudflare issue #942
  「Cloudflare build crashes on catch-all API route `/api/auth/[...better-auth]` due to invalid regex」
  https://github.com/opennextjs/opennextjs-cloudflare/issues/942
  本项目正是 `app/api/auth/[...all]/route.ts`（better-auth 官方 Next 处理器）→ **迁移前必须先在 spike 里验证**。
  另一个相关 issue #345「getCloudflareContext gives error on catch-all routes」。
- **图片处理有官方 binding**：Workers 的 Images binding
  https://developers.cloudflare.com/workers/runtime-apis/bindings/（Images 一栏）
  https://developers.cloudflare.com/images/optimization/binding/
  → 可作为 sharp 的替代；**但其计费与免费额度待核实**。

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

### 1.3 已知的硬骨头（Postgres → SQLite）

迁移不是"换个连接串"，以下都要改：

- `SELECT DISTINCT ON (image.id)` —— 现有索引迁移里用到了，**SQLite 不支持**，要改写成窗口函数或子查询。
- **JSON 操作符**：现有表达式索引用 `exif->>'model'` / `exif->>'lens_model'`，SQLite 是 `json_extract`。
- `@db.SmallInt` / `@db.Text` / `@db.Timestamp` 等 Postgres 专有类型标注要去掉。
- 枚举、自增、`now()` 默认值等语义差异。
- Prisma 的迁移目录（`prisma/migrations/*`）是 Postgres SQL，迁到 D1 需要**重做一套 SQLite 迁移**。

## 2. 分阶段计划

### Phase 0 —— 可行性 spike（不碰主站）
目标：在**不影响线上**的前提下，回答 1.2 里的四个问题。
- [x] P0-1 核实 Workers 免费/付费 CPU 上限与计费 —— **已完成**（见 1.2：免费 10ms 不够 SSR，付费 5 分钟）
- [ ] P0-2 在付费账号上跑一个 `@opennextjs/cloudflare` 最小 Next 应用，**带一个 catch-all 路由**
      验证 issue #942 是否已修（若未修，找出绕过方式：路由改写 / 降级 better-auth handler）
- [ ] P0-3 最小 Prisma + D1 例程（一张表、一次读一次写），确认 `@prisma/adapter-d1` 可用
      —— 注意：本项目 Prisma 为 6.4.1，而适配器稳定版最早可见 6.19.3，**需要先做一次 Prisma 升级**并单独验证
- [ ] P0-4 Images binding 缩放一张真图，确认能替代 sharp 的预览图管线，并查清计费
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
