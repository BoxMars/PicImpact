# PicImpact 全站性能优化设计（Spec）

- **日期**：2026-10-03
- **目标仓库**：`/Users/box/Work/PicImpact` @ `f1bfcdb`
- **生产地址**：`https://felina.boxz.dev`（Cloudflare 前置，回源 Next.js standalone）
- **资产域**：`https://felina-asset.boxz.dev`（R2 自定义域）
- **状态**：设计待评审 → 通过后进入 `writing-plans`

---

## 1. 背景：实测基线

用户报障：**整个页面很卡顿**，四个症状全中——首屏慢、滚动掉帧、跳转/预览延迟、后台尤其 `/admin/upload` 卡。

本设计的每一条根因都来自实测，不是静态猜测。测量手段：

| 手段 | 覆盖范围 |
|---|---|
| 真实生产构建（`next build`，Turbopack，Next 16.1.6） | 路由 JS/CSS 体积、chunk 归属、字体产物 |
| `build-manifest.json` + `*_client-reference-manifest.js` 解析 | 逐路由首屏资源清单 |
| Cloudflare 线上 `curl -I`（3 次） | TTFB、缓存头、`cf-cache-status` |
| 首屏 HTML 中 40 个真实图片 URL 全量 `HEAD` | 首屏图片字节总量 |
| `sharp` 读取原图/preview 元数据（DB 配对查询） | 图片真实像素尺寸 |
| Prisma 只读 `SELECT` | `preview_url` 覆盖率、JSON 字段体积 |
| 打包库源码阅读（`animal-island-ui`、`react-photo-album`） | DOM 节点数、重渲染行为 |

### 1.1 首屏关键指标

| 指标 | 实测值 |
|---|---|
| TTFB（3 次） | **2.33 / 2.51 / 2.50 秒** |
| HTML 体积 | **802 KB** |
| 客户端 JS | 1,119.7 KB 原始 / **357.4 KB gzip** |
| CSS | 516.5 KB 原始 / 63.2 KB gzip |
| 中文字体 | **3,391.6 KB**（3 个 CJK woff2，`unicode-range` 数量 = 0） |
| 首屏图片 | **≈ 118.5 MB** |
| 路由渲染模式 | **26 / 26 全部 `ƒ Dynamic`** |

### 1.1.1 Cloudflare 缓存实测（**已修正**）

早期测量用 `HEAD`（`curl -I`）得出"资产域未缓存"的结论，**该结论是错的**：Cloudflare 不缓存 HEAD 请求。用真实 `GET` 重测后：

| 资源 | `cf-cache-status` | 说明 |
|---|---|---|
| `/_next/static/chunks/*.js` | **HIT** | `age: 180634`，`max-age=31536000, immutable` |
| `felina-asset.boxz.dev/images/**`（直连） | **HIT** | `age: 1358`，`cache-control: max-age=14400` |
| `/api/public/url-proxy?url=…` | **DYNAMIC** | 无文件扩展名 → Standard 缓存级别不存储该路径 |
| 首页 HTML | **DYNAMIC** | 动态渲染（见 R4），符合预期 |

**修正后的结论**：资产域自身的边缘缓存是**正常工作的**。真正的损失是**所有图片都被强制绕经 `/api/public/url-proxy`** —— 这个路径不可缓存，于是每次图片请求都要多一次源站往返，边缘缓存带来的收益被完全抵消。因此图片链路的首要修复是**把代理从图片路径上摘掉**（纯代码改动），而不是新增边缘缓存规则。

Cloudflare Containers 明确要求 Workers 付费计划（API 返回 401 `Deploying containers requires the Workers Paid plan`），账号下的 4 个 Worker 脚本均与本项目无关 → **本项目的 Next.js 源站跑在 Cloudflare 之外的服务器上**，这解释了 2.4s 的 TTFB（源站 + 东京数据库往返）。

### 1.2 首屏图片字节明细（24 张卡片）

| 类别 | 数量 | 总计 |
|---|---|---|
| `url` 原图（JPEG） | 24 | **82.73 MB**（均 3.45，最大 5.31，最小 1.50） |
| `preview_url` | 16 | **40.05 MB** |
| └ 正常 webp 分片 | 14 | 3.90 MB（0.08–0.71 MB） |
| └ **12MP PNG 伪装成缩略图** | 2 | **21.76 MB + 14.12 MB** |
| └ 无独立缩略图，HTML 直接给原图 | 8 | — |

**同一 id 的原图/preview 配对实测（`sharp`）**：

```
{"db_wh":"4032x3024","original":{"px":"4032x3024","mb":"2.00"},"preview":{"px":"4032x3024","mb":"0.24"}} -> 像素尺寸完全相同
{"db_wh":"4032x3024","original":{"px":"4032x3024","mb":"4.03"},"preview":{"px":"4032x3024","mb":"0.25"}} -> 像素尺寸完全相同
{"db_wh":"4032x3024","original":{"px":"4032x3024","mb":"3.85"},"preview":{"px":"4032x3024","mb":"0.71"}} -> 像素尺寸完全相同
{"db_wh":"4284x5712","original":{"px":"5712x4284","mb":"2.93"},"preview":{"px":"4284x5712","mb":"0.15"}} -> 宽高互换
```

结论：**`preview_url` 从未被缩放，只被换过格式。**

---

## 2. 目标与非目标

### 2.1 目标（可测量）

| 指标 | 现状 | 目标 |
|---|---|---|
| 首屏图片字节 | 118.5 MB | **< 2 MB** |
| 单张网格图解码像素 | 12.2 MP（×2 层） | **< 0.2 MP**（约 400×300） |
| TTFB | 2.4 s | **< 0.5 s** |
| 首屏 JS | 357.4 KB gzip | **< 200 KB gzip** |
| 每页 CSS | 483.6 KB 原始 | **< 80 KB 原始**（实测已达 180.0 KB；字体分片后又升至 477 KB 原始 / 129.5 KB gzip，见 R8） |
| 字体 | 3,391 KB | ~~< 150 KB~~ **实测 1,666 KB**（原目标基于被证伪的频率聚类假设，见 R8） |
| 首次导航人为阻塞 | 1000 ms | **0 ms** |
| 每次客户端跳转人为阻塞 | 700 ms | **0 ms** |
| 网格每方块 DOM 节点 | ~130 | **< 20** |
| 图片边缘缓存 | 代理路径 DYNAMIC | 直连资产域 **HIT**（已达成） |

### 2.2 非目标（明确排除）

- 不改数据模型结构（`images` / `albums` / `configs` 表结构保持；仅新增索引与可选的派生列）。
- 不改视觉设计语言（配色、圆角、卡片样式、"动物森友会"风格保持不变）。
- 不改业务功能语义（相册、标签、EXIF 展示、地图、后台管理能力全保留）。
- 不做与性能无关的重构、不升级大版本依赖。
- 不处理上游开源项目的兼容性（本项目按自身需要演进）。

---

## 3. 已确认的产品决策

| 决策 | 选择 | 影响 |
|---|---|---|
| 中文字体 | **接受「零视觉变化」的 unicode-range 子集化** | 保留 Nunito + Noto Sans SC、字形字重完全一致，仅改为分片按需加载 |
| 缩略图方案 | **B：用 sharp 批量重生真缩略图 + 重写上传流程** | 需一次性迁移现有 39 张；不依赖付费服务 |
| Cloudflare 配置 | **用户重新 `wrangler login`，由本会话直接操作** | 可加 Cache Rule、查 Containers/Workers 配置并复测 |
| 缓存层 | 允许 `unstable_cache` / 边缘缓存 / 页面静态化 | P2 可落地 |
| 死代码清理 | 允许（HeroUI CSS、未用依赖、next-pwa、幽灵依赖） | P1 可落地 |
| `next/image` 真实优化 | 允许 | P0 可落地 |
| 视觉动效 | 允许砍掉/简化（GSAP 过场、Typewriter、自定义光标、常驻无限动画） | P1 可落地 |

---

## 4. 根因清单

按用户可感知影响排序。每条给出：证据 → 机制 → 影响。

### R1（致命）缩略图管线从不缩放，且网格每张卡片额外下载原图

**证据**

- `components/admin/upload/multiple-file-upload.tsx:156-174`（同样逻辑在 `simple-file-upload.tsx:204`、`livephoto-file-upload.tsx:199`）：
  ```js
  new Compressor(file, {
    quality: previewCompressQuality,
    checkOrientation: false,
    mimeType: 'image/webp',
    maxWidth: previewImageMaxWidthLimitSwitchOn && previewImageMaxWidthLimit > 0
      ? previewImageMaxWidthLimit : undefined,
  ```
  `maxWidth` 默认为 `undefined` → Compressor 只重编码、不缩放。`mimeType: 'image/webp'` 在编码失败时回落原格式 → 产出 12MP PNG。`checkOrientation: false` → 宽高/方向错乱。
- `components/gallery/simple/gallery-image.tsx:29-32`：`thumbUrl = preview_url`、`hdUrl = url`（原图）。
- 同文件 `:46-61`：mount 时对每张卡片无条件 `new window.Image(); img.src = resolvedHd` 并 `await img.decode()`，**无 viewport 门控**。
- 同文件 `:135-152`：`<img src={resolvedHd}>` 叠在缩略图上，**无 `loading`、无 `decoding`** → 同步主线程解码。
- 全部图片 `unoptimized`：`gallery-image.tsx:121`、`blur-image.tsx:41`、`progressive-image.tsx:134`、`list-image.tsx:19`、`image-view.tsx:63`、`nav-title.tsx:29`。
- 线上主题确认为 simple（首屏 HTML 含 24 个 `island-simple-card`、0 个 `island-blur-image`）。

**机制**：24 张卡片 × (12.2 MP 缩略图 + 3.45 MB 原图)，原图被 `decode()` 一次、作为 `<img>` 再同步解码一次。首屏 118.5 MB、解码量约 600 MP。

**影响**：首屏慢与滚动掉帧的主因，单项即解释大部分报障。

#### R1.1 实施后的实测修正（2026-10-03）

计划里"Task 1 可省 82.73 MB"的估计**不准确**，实测如下：

| 阶段 | 首屏图片字节 | 说明 |
|---|---|---|
| 改动前 | 122.78 MB | 16 preview + 24 原图（原图既作缩略图兜底又作 HD 图层） |
| Task 1 后（实测） | **68.55 MB** | 省 **54.23 MB**；HD 图层与冗余预加载已消除 |
| P0.2 后（预期） | ≈ 2–3 MB | 生成真实 400px 缩略图后 |

**剩余 68.55 MB 的构成**：

| 来源 | 字节 |
|---|---|
| 8 张**空 `preview_url`** 的照片 → 回退加载原图 | 28.50 MB |
| 16 张 preview（其中 2 张是 12MP PNG） | 40.05 MB（35.88 MB 来自那 2 张 PNG） |

#### R1.2 新发现的数据缺陷：`preview_url` 为空字符串（不是 NULL）

**证据**：只读查询实测——`images` 表中 `del = 0` 共 39 行，其中 **8 行 `preview_url = ''`（空字符串）**，`preview_url IS NULL` 为 0 行。首页精确复现查询（`server/db/query/images.ts:181-196`，条件 `del = 0 AND show = 0 AND show_on_mainpage = 0`，按 EXIF 拍摄时间排序，`LIMIT 24`）返回的 24 行里正好有 **8 行**为空。

**为什么之前被漏判**：初版聚合查询用 `COUNT(preview_url)` 统计"有缩略图"的覆盖率，而 SQL 的 `COUNT(col)` **不把空字符串视为 NULL**，因此 8 行空串被计为"有值"，得出"39/39 都有 preview"的错误结论。

**后果**：`components/gallery/simple/gallery-image.tsx:29` 的 `thumbUrl = photo.preview_url || photo.url` 对空字符串求值为假 → 回退到全分辨率原图作为网格缩略图。经 HTML 逐条比对，这 8 个 id 与页面中 8 个 `src=原图` 的 `<img>` **完全一一对应**。

**归属**：由 P0.2 的历史数据迁移修复（迁移脚本必须同时处理 NULL、空字符串、以及"格式/尺寸不合格"三类不合格值，判据是"最长边 ≤ 400 且为 webp"，而不是"非 NULL"）。

### R2（高）网格无虚拟化、无限追加、CSS 多列全量重排

**证据**：`server/db/query/images.ts:19` `DEFAULT_SIZE = 24`；`components/layout/theme/simple/simple-gallery.tsx:48` `[].concat(...data)` 只追加不回收；同文件 `:119` `columns-1 sm:columns-2 lg:columns-3`（CSS `columns` 每次追加都重排整个容器）；全仓库无虚拟化库。

**机制**：每次 `setSize(size+1)` 重渲染并重排全部已累积分片 → 单次会话 O(n²)；DOM 与内存线性增长。

**影响**：越滚越卡，与"滚动掉帧、图片一张张卡着出来"完全吻合。

### R3（高）每方块 ~130 个 DOM 节点，其中 ~108 个来自 9 个 Tooltip

**证据**：`components/gallery/simple/gallery-image.tsx:226,234,242,250,258,299,311,325,332` 共 9 个 `animal-island-ui` `Tooltip`；库实现 `node_modules/animal-island-ui/dist/es/components/Tooltip/Tooltip.js` 即使隐藏也渲染约 12 个元素（含 2 个 SVG，`path d` 长 709 字符），CSS 为 `position:absolute; opacity:0` 而非 `display:none`。

**机制**：240 张时约 2,160 个 `clipPath`、约 3 MB 重复 SVG 路径文本；每次样式重算遍历 9 个额外绝对定位子树。

### R4（高）全站永久动态渲染 + 零缓存

**证据**：`app/layout.tsx:57` `await getLocale()` → `i18n.ts:7` → `lib/utils/locale.ts:10` `(await cookies()).get(COOKIE_NAME)`。全仓库 `unstable_cache` / `cache()` / `revalidate`（页面级）= **0 处**。生产实测：`cache-control: private, no-cache, no-store, max-age=0, must-revalidate`、`cf-cache-status: DYNAMIC`。

**机制**：`cookies()` 让整棵路由树失去静态化能力；Cloudflare 永远无法缓存页面；每次浏览都重跑 4~6 次东京 Supabase 查询。

### R5（高）查询重复与串行

**证据**：`app/layout.tsx:24` 与 `:61` 是两次独立 config 查询；`app/(default)/page.tsx:31` 先 `await getConfig()` 再 `Promise.all`（可并行）；`server/db/query/images.ts:47-50` 在列表查询前先 `fetchConfigValue`；同文件 `:198-206` `albums.findFirst` 后才查列表；`fetchAlbumsShow` 在 `(default)/layout.tsx:14`、`(theme)/[...album]/layout.tsx:16`、`(theme)/map/layout.tsx:13` 各调一次。

### R6（高）首屏加载约 325 KB 死 CSS

**证据**：`style/globals.css:2` `@import "@heroui/styles"`；全仓库 `@heroui/react` 引用数 = **0**。生产 CSS `67032e29803994d7.css`（483.4 KB）中实测存在 HeroUI 组件选择器：`.number-field`×110、`.menu`×94、`.toast`×70、`.accordion`×54、`.date-picker`×36、`.chip`×27。`@heroui/styles` 自身 CSS 合计 523.8 KB，其中 `heroui.min.css` 为 324.7 KB。

**机制**：Tailwind v4 的 `@import` 是构建期内联，未被引用的库样式照样全量产出，且每条路由都加载。

**精度声明**：HeroUI 的选择器**已确认存在于**产出 CSS 中（见上），但"325 KB"这个数字来自 HeroUI 自身 CSS 的体积，**不是**逐字节归因。确切贡献必须用 A/B 构建测定（加/不加该 `@import` 各构建一次，对比产出体积）。P1.1 的第一步就是这个 A/B 测量，以实测值而非估算值作为验收依据。

### R7（高）每次导航被强制盖 700–1000ms 全屏 GSAP 动画

**证据**：`app/providers/progress-bar-providers.tsx:7` `MIN_DISPLAY_MS = 700`；`:40-44` 首屏 `setTimeout(…, 1000)`；`:60-68` 猴补丁 `window.history.pushState`；`:86-103` 渲染 `100vw×100vh`、`z-index: 9999` 的 `animal-island-ui` `Loading`。该组件的 gsap 依赖：`Loading/island/gsap.min.js`(80,279 B) + `MotionPathPlugin.min.js`(27,060 B)，构建后 chunk `da2f3b2cd20b5ae1.js` = 88.8 KB 原始 / 36.0 KB gzip，**实测在首页 chunk 列表内**。

### R8（中，**已按实测下调**）3.39 MB 中文字体，零 unicode-range 门控

**证据**：`style/globals.css:4` `@import "animal-island-ui/style"` → `dist/index.css` 内联 9 条 `@font-face`，其中 `noto-sans-sc-chinese-simplified` 400/500/700 分别为 1115.8 / 1132.0 / 1144.8 KB，`unicode-range` 数量 = **0**。`style/globals.css:160-161` body 字体栈含 `'Noto Sans SC'` 且 `font-weight: 500`。

**对照**：`@fontsource/noto-sans-sc@5.2.9` 每个字重自带 **101 个 unicode-range 分片**。

**⚠️ 实测修正（2026-10-03，实施后）**：原设计假设"分片 = 按需加载几十 KB"，该假设**被实测证伪**。Noto Sans SC 的 101 个分片是按**码点区间**切分的，不是按使用频率聚类。实测线上首页（509 个唯一中文字符）命中 **18/101** 个分片，每字重约 **550 KB**：

| 字重 | 命中分片 | 下载量 |
|---|---|---|
| 400 | 18 / 101 | 549.5 KB |
| 500 | 18 / 101 | 555.8 KB |
| 700 | 18 / 101 | 560.3 KB |
| **合计** | | **1,665.6 KB** |

- **字体净收益**：3,391.6 KB → 1,665.6 KB，**省 1,726 KB**（不是原估的 3.2 MB）。
- **CSS 代价**：318 条 `unicode-range` 声明使全局 CSS 的 gzip 从约 30 KB 升到 **129.5 KB**（原始 63.2 KB），且这部分在**渲染阻塞**路径上。
- 字重集合与原状**完全一致**（Noto Sans SC 仅 400/500/700，Nunito 仅 500/700/900），故"零视觉变化"成立；400 确实在用（7 处 `font-normal`），不可删。
- **未采取的更优方案（后续可选）**：用 `fonttools` 按使用频率做自定义子集（如 GB2312 一级字库 3,500 字），可得每字重约 250–350 KB、仅 3 条 `@font-face`（CSS 回到约 30 KB），总量约 1 MB —— 优于当前的 1.67 MB + 129.5 KB。代价是子集外生僻字回退系统字体，且需引入 Python 子集化步骤。

### R9（中高）代码分割缺失

- `app/(theme)/[...album]/page.tsx` 静态 import **全部三种**画廊，运行时才按 config 选择。
- `motion` 被打进**两个** 105.7 KB chunk（`3e12c29753a5cf99`、`7fcb51cd213a5172`）；首页加载前者。
- `/admin/upload` 首屏 **4,040.4 KB**，因 `heic-to` + `exifreader` 同处 2,828.9 KB chunk。
- `components/album/progressive-image.tsx:8` 静态 import `WebGLImageViewer`（2,140 行 + worker），而 `showLightbox` 从未被 `preview-image.tsx` 传入 → 永不可达。
- 全仓库仅 **1 处** `next/dynamic`。
- （已排除：maplibre 977 KB chunk **不在** `/map` 首屏，react-map-gl 自行懒加载。）

### R10（中）预览页多取两张图 + 主线程像素分析

**证据**：`components/album/preview-image.tsx:131,187-201,344-357`；`tone-analysis.tsx:126-133` 与 `histogram-chart.tsx:212-219` 在跨域分支下带 `&_t=${Date.now()}` 重新请求，缓存必然失效；`tone-analysis.tsx:20-91` 构建 4 万项亮度数组；`histogram-chart.tsx:21-55` 同步遍历 9 万像素；同文件 `:314-337` 动画分支每帧 `drawHistogram`，`:114-146` 渐变**逐条创建**、每帧 4 次 → 512 个渐变对象/帧，且 `:62` 在帧内 `getBoundingClientRect()` 与 `:67-71` 画布写入交错（强制布局抖动）。

### R11（中）后端查询与索引

**证据**：`server/db/query/images.ts:17,194` 按 `COALESCE(TO_TIMESTAMP(COALESCE(image.exif->>'data_time', image.exif->>'date_time'), …))` 排序（JSON 派生表达式，不可索引）；`:116,141,254,274,382` 计数用 `SELECT DISTINCT ON (image.id)` 全表扫描；`:308-336` `fetchMapImages` **无 LIMIT** 且 `select image.exif`；`:235-237` 在 `LIMIT` 之后 `sort(() => Math.random() - 0.5)`（导致无限滚动重复/漏图）。索引现状：仅 `prisma/migrations/20250226144408_add_json_field_indexes/migration.sql:2,5` 的 `exif->>'model'`、`exif->>'lens_model'`；`images` 无 `del/show/sort/created_at` 索引；`images_albums_relation` 主键为 `("imageId","album_value")`，`album_value` 单列无法命中。

### R12（中）重渲染与监听器

- `components/layout/dock-menu.tsx:16` 与 `components/layout/command.tsx:25-27`：`useButtonStore((state) => state)` 订阅整个 store；`authClient.useSession()` 在每个主题页挂载。
- `components/ui/origin/infinite-scroll.tsx:23-38`：deps 含内联 `next`（调用方 `simple-gallery.tsx:113`、`default-gallery.tsx:128` 传内联箭头）→ 每次渲染重建 observer，且 `observe()` 立即投递一次 entry → 多余翻页。
- `components/layout/theme/default/default-gallery.tsx:139-147`、`components/album/tag-gallery.tsx:87-94`：内联 `photos` 数组与 `render` 对象，破坏 `react-photo-album` 的 `useMemo([photos, …])` 记忆化。
- `components/layout/theme/map/map-view.tsx:73-79,114`：maplibre `move` 每帧 `setBounds`+`setZoom` → 60Hz React 重渲染 + supercluster 重算。
- `components/ui/origin/draggable-card.tsx:68-98,100-116`：**每张卡片**一个未节流 `resize` 监听（内部 `setConstraints` + 多次 rect 读取），`onMouseMove` 每次 `getBoundingClientRect()`；`hooks/use-mobile.ts:8-16` 每卡片一个 `matchMedia` 订阅。

### R13（低）其他确认项

- `style/globals.css:243-245` `* { cursor: url('/cursor-icon.png') 4 0, auto !important; }` 全局强制位图光标。
- `next-pwa` 已配置但构建后 `public/` **无 sw.js**、前端无注册代码 → PWA 实际未生效（Turbopack 下 next-pwa 的 webpack 钩子不执行）。
- 幽灵依赖 `@radix-ui/react-visually-hidden`（`app/@modal/(...)preview/[id]/modal.tsx:5`）未声明，严格安装下构建失败。
- `next.config.mjs` 的 `eslint` 键在 Next 16 已失效；`typescript.ignoreBuildErrors: true` + `eslint.ignoreDuringBuilds: true` 掩盖以上问题。
- 零引用依赖：`@heroui/react`、`recharts`、`react-day-picker`、`embla-carousel-react`、`vaul`、`heic2any`、`dayjs`、`date-fns`。
- 死代码：`components/album/floating-filter-ball.tsx`、`components/album/camera-lens-filter.tsx`、`components/ui/carousel.tsx`、`/api/public/camera-lens-list` 路由（唯一调用方是死代码）、`useIsHydrated`、`usePasskeyStatus`、`ui/origin/dock.tsx`、`text-counter.tsx`、`evervault-card.tsx`。
- `hono/open/images.ts:12`、`hono/open/download.ts:45-46` 用 `await response.blob()` 整文件入内存。
- DB 宽高与实际像素不符（`4284x5712` vs 实际 `5712x4284`），根因是 `checkOrientation: false`。

### 4.1 已验证无问题（不再重复排查）

- `/api/public/url-proxy` 是**流式**转发（`route.ts:78-81`），不缓冲，内存 O(1)。
- 代理**已设置** `Cache-Control`（`route.ts:3-4,62-67`）——问题只在边缘不存储。
- 预签名 URL **不在**画廊图片链路（仅下载/上传用到），不存在过期导致的缓存失效。
- 服务端数据层**无 N+1**、无 `.map()` 内 `await`。
- 客户端**无轮询**（全仓库 `refreshInterval` = 0）；所有 SWR 均已关闭 focus/stale/reconnect 重验。
- 首页/标签页**不存在 hydration 双取**（`initialImages`/`initialPageTotal` 已作为 `fallbackData` 传入）；`/[album]` 是例外（见 R14）。
- 画廊路径**无布局属性动画**（全为 `opacity`/`transform`）；键值稳定。
- 应用代码**无** scroll/resize 驱动的 `setState` 风暴。
- `thumbhash` 解码是纯 JS（无 canvas/`getImageData`），不是热点。
- `ProgressBarProviders` 在动画后会卸载 GSAP（`:31-34,86-103`），不是常驻 60fps 循环。
- `useTranslations` 返回记忆化函数，`progressive-image.tsx:112` 的 effect 不会死循环。

### R14（高）专辑页双段瀑布

**证据**：`app/(theme)/[...album]/page.tsx:40-48` 的 props **不含** `initialImages` / `initialPageTotal` / `initialConfigData`（对比 `app/(default)/page.tsx:44-46`）；消费方 `default-gallery.tsx:43`、`simple-gallery.tsx:30,47` 的 `fallbackData` 因此为 `undefined`。

**机制**：RSC 只出空壳 → 水合 → 再 POST server action 回源（每次都是新的动态请求 + 查库）→ 才出图。

---

## 5. 架构总览

四个阶段，按"收益/风险"排序。P0+P1 解决三个症状（首屏慢、滚动卡、后台卡），P2 解决"点哪都慢"，P3 消除剩余重渲染与打包浪费。

| 阶段 | 主题 | 对应根因 | 风险 |
|---|---|---|---|
| **P0** | 图片管线：真正的缩略图 + 边缘缓存 | R1, R2(部分), R10(部分) | 中（数据迁移 + 上传流程改写） |
| **P1** | 去死重量与人为延迟 | R6, R7, R8, R13 | 低（R7/R8 已获视觉授权） |
| **P2** | 打破动态渲染与缓存 | R4, R5, R11, R14 | 中（R4 影响 i18n 取语言方式） |
| **P3** | 渲染与打包 | R2(剩余), R3, R9, R12 | 低-中 |

---

## 6. 详细设计

### P0 — 图片管线

#### P0.1 服务端缩略图生成（新能力）

新增 `server/lib/thumbnail.ts`，用 `sharp`（已装 0.34.5）从原图 Buffer 生成多档：

| 档位 | 最大边长 | 格式 | 用途 |
|---|---|---|---|
| `thumb` | 400 | webp（`quality 72`） | 网格方块 |
| `medium` | 1200 | webp（`quality 78`） | 平板 / 高分屏网格、预览占位 |
| `large` | 2000 | webp（`quality 80`） | 预览页 |

要求：

- 用 `.rotate()` 应用 EXIF 方向后再 `resize`，消除 R13 的方向/宽高错乱；同时把校正后的真实宽高写回 DB。
- 输出必须是 `image/webp`；**编码失败时不得回落为 PNG/JPEG 原图**，应显式报错，避免再次产生 21.76 MB 的"缩略图"。
- 契约：`generateThumbnails(input: Buffer) => Promise<{ thumb: Buffer, medium: Buffer, large: Buffer, width: number, height: number }>`。

#### P0.2 历史数据迁移

新增 `scripts/migrate/regenerate-previews.ts`（沿用现有 `scripts/migrate/` 与 `package.json` 脚本命名风格）：

- 扫描 `images` 中 `del = 0` 的行；对每行下载 `url` → 生成三档 → 上传到既有存储（复用 `server/lib/s3.ts` / `server/lib/r2.ts` / `hono/file.ts` 的既有上传能力）→ 回写 `preview_url`（指向 `thumb`）与新宽高。
- 幂等：已存在且格式为 webp 且最长边 ≤ 400 的 preview 跳过；`--force` 可重跑。
- 现状规模 39 行，可一次跑完；脚本需支持限流与断点续跑。
- **必须先产出 dry-run 报告**（列出计划变更、预计字节变化）供人工确认，再加 `--apply`。

#### P0.3 上传流程改写

现状：`components/admin/upload/{multiple,simple,livephoto}-file-upload.tsx` 在**浏览器端**用 Compressor.js 生成 preview，且 `maxWidth` 被一个默认关闭的开关（`previewImageMaxWidthLimitSwitchOn`）挡住。

改为：

- 浏览器端只做**上传前瘦身**（HEIC 转换、超大原图压缩），不再承担缩略图职责。
- 缩略图统一由**服务端**在入库时调用 P0.1 生成；`preview_url` 由服务端写入，不再由客户端传入。
- 保留管理界面的"手动指定 URL"输入框作为逃生通道，但需在 UI 上标注"非受管缩略图，不影响网格性能"。
- 移除对 `previewImageMaxWidthLimitSwitchOn` 的依赖：档位是代码里的常量，不做成开关。

#### P0.4 网格只加载缩略图

改 `components/gallery/simple/gallery-image.tsx`：

- 删除 `:46-61` 的整段原图预加载 `useEffect`。
- 删除 `:135-152` 的 HD 原图层。网格**只渲染缩略图**。
- 若确实要保留"原图已就绪"的 HD 徽标，改为 `IntersectionObserver` 命中且浏览器空闲（`requestIdleCallback`）时才预取，并限制并发（如 ≤ 3）；默认行为改为**点击进预览页看原图**。
- 移除 `unoptimized`（`:121`），补 `sizes`：三列布局下 `(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw`。
- 首屏前 2~4 张加 `priority` / `fetchPriority="high"`（当前全仓库无任何 `priority`）。

同类处理：`components/album/blur-image.tsx:41`、`components/album/progressive-image.tsx:134`、`components/admin/list/list-image.tsx:19`、`components/admin/list/image-view.tsx:63`、`components/layout/admin/nav-title.tsx:29` —— 逐处判断该用真实优化还是保留 `unoptimized`（`nav-title` 的 logo 属于本地小图，可保留）。

`components/layout/theme/polaroid/polaroid-gallery.tsx:92-111` 的 `sizes="(max-width:768px) 100vw, (max-width:1200px) 50vw, 33vw"` 与固定 175–376px 卡片宽度不符，需按实测卡片宽重写。

`components/layout/theme/map/map-view.tsx:218-223` 的 `next/image fill` 缺 `sizes`（默认 `100vw`），补 `sizes="320px"`。

#### P0.5 预览页按需取原图

改 `components/album/progressive-image.tsx`：

- 保留 `preview` 优先、原图后到的顺序，但原图请求改为**预览页打开后**触发，不在挂载时就 eager。
- `tone-analysis` / `histogram-chart`：去掉 `&_t=${Date.now()}` 缓存破坏；改为复用已加载并解码的 `HTMLImageElement`（或传入同一个已 fetch 的 `Blob`/`ImageBitmap`），避免重复下载与重复解码。
- 分析前先降采样（例如缩到 ≤ 512px 再 `getImageData`），把 4 万/9 万像素循环的输入量降两个数量级。
- 两个面板改为按需加载（用户展开时才计算）。
- `histogram-chart.tsx:114-146` 改为复用单个渐变对象、把 `getBoundingClientRect()` 移出帧循环；`:314-337` 的动画限制为单次绘制而非 1.2s 逐帧。

#### P0.6 虚拟化 / 上限

改 `components/layout/theme/simple/simple-gallery.tsx` 与 `components/layout/theme/default/default-gallery.tsx`：

- 引入窗口化（`react-virtuoso` 或自写基于 IntersectionObserver 的窗口），或对 CSS `columns` 方案改回可控的网格 + 保留窗口。
- 无论选哪种，都要**限制保留分片数上限**（例如最多保留最近 5 页 / 120 张），超出则回收。
- 修复 `server/db/query/images.ts:235-237` 的 `LIMIT` 后随机排序：改为 SQL 侧带 seed 的稳定随机，或在分页模式下禁用随机。

#### P0.7 图片路径摘除代理（P0 的关键修复，纯代码）

**依据修正后的实测**（见 1.1.1）：资产域边缘缓存本来就是 HIT，罪魁是 `/api/public/url-proxy` 不可缓存。

- 把 `lib/utils/image-proxy.ts` 的 `toProxyImageUrl` 改为**默认恒等**（直接返回原始资产 URL），仅在明确需要跨域/防盗链的场景保留代理。
- 前提校验（必须先做）：资产域是否允许跨域直连 —— 检查 `felina-asset.boxz.dev` 是否带 `Access-Control-Allow-Origin`、是否依赖 `Referer` 防盗链。若不满足，则改为在 CF 层给代理路径加 Cache Rule（见下）作为替代而非直连。
- `<img>` / `next/image` 直接指向 `felina-asset.boxz.dev`，浏览器与 CF 边缘都按 `max-age=14400` 命中。
- 代理路由**保留**作为兜底能力，但不再位于默认关键路径上。

#### P0.7b Cloudflare 侧（可选增强，需要 zone 级权限）

当前 OAuth token 只有 account 级 Workers/Pages 权限，`/zones/{id}/settings`、`/zones/{id}/rulesets`、`/zones/{id}/pagerules` 全部 403。若要进一步压榨边缘收益，需要用户提供带 **Zone → Cache Rules → Edit** 与 **Zone → Cache Rules/Zone Settings → Read** 的 API Token（或在面板操作）：

- 为资产域加 Cache Rule：`Browser TTL` 覆盖为 1 年（文件名是内容哈希，内容不可变）→ 回访完全不走网络。
- 为 `/api/public/url-proxy*` 加 Cache Rule（Cache Everything）—— 仅在 P0.7 无法直连时才需要。
- 中间件 `proxy.ts:26-31` 的 matcher 排除 `/api/public/*` 与常见静态资源后缀（此项是纯代码，无需 CF 权限）。

**验证**：同一图片 URL 连续两次 `GET`，第二次必须 `cf-cache-status: HIT` 且不再产生源站请求；`/_next/static` 保持 HIT。

#### P0.8 中间件放行静态与图片路径

`proxy.ts:26-31` 的 matcher 目前只排除 `_next/static`、`_next/image`、`favicon.ico`，因此每个图片请求（含代理路径）与 `public/` 资源都会经过中间件。扩宽负向断言，排除 `/api/public/*`、`/icons/*`、`/fonts/*` 及常见静态后缀；`/admin` 与 `/api/v1` 的鉴权保持不变。

（原"服务端图片路径保持一致"一节已并入 P0.7。）

---

### P1 — 去死重量与人为延迟

#### P1.1 删除 HeroUI 死 CSS（省约 325 KB/页）

- 删除 `style/globals.css:2` 的 `@import "@heroui/styles"`。
- 从 `package.json` 移除 `@heroui/react` 与 `@heroui/styles`（代码零引用）。
- **验证**：构建后 `grep -c "number-field\|\.toast\|\.accordion"` 于产出的全局 CSS 应为 0；全局 CSS 原始体积应从 483.4 KB 降到约 80 KB。

#### P1.2 中文字体按需分片（省约 3.2 MB）

- 不再使用 `animal-island-ui/style` 内联的 9 条未分片 `@font-face`。
- 改为引入 `@fontsource/noto-sans-sc/{400,500,700}.css` 与 `@fontsource/nunito/{500,700,900}.css`（`@fontsource/noto-sans-sc@5.2.9` **已安装**，400.css 含 101 条 `unicode-range`，每个分片仅几十 KB）。
- 推荐做法（确定性）：加一个极小的 PostCSS 步骤，从 `animal-island-ui` 的 CSS 中剥离指向 `files/noto-sans-sc-*` / `files/nunito-*` 的 `@font-face` 规则，其余组件样式（61.3 KB）保留。
  - 备选做法（更简单但依赖层叠顺序）：在 `animal-island-ui/style` 之后引入 fontsource 的 CSS，靠后声明覆盖同族同字重的未分片 face。两条路都必须实测验证，不允许"看起来应该行"。
- 把 `@fontsource/*` 从传递依赖提升为**直接依赖**（显式声明，不靠提升）。
- **验证**：构建产物里不得再出现 `noto-sans-sc-chinese-simplified-*.woff2`（1.1 MB 级文件）；网络面板中文字体实际下载量 < 150 KB；中文字形与现状一致（截图对比）。

#### P1.3 砍掉全屏 GSAP 过场（省 36 KB gzip + 每次 700–1000ms）

- `app/providers/progress-bar-providers.tsx`：移除 `animal-island-ui` 的 `Loading`（连带移除 gsap + MotionPathPlugin + 11.7 KB 内联 SVG）。
- 移除 `MIN_DISPLAY_MS` 人为下限与首屏 1000ms 等待；改为**只反映真实 pending 状态**（`useLinkStatus`/`useTransition`/路由事件），无 pending 时不显示任何遮罩。
- 移除对 `window.history.pushState` 的猴补丁。
- 如果确实要保留品牌过场，则改为纯 CSS（transform/opacity）方案，且不再有最小显示时间；这属于视觉决策，需在计划评审时确认。
- `components/layout/theme/*/*.tsx` 里的 `Icon bounce` 与 `Typewriter speed={55,60}`：`Typewriter` 用 `setInterval(55ms)` 逐字符重渲染约 30 帧，恰与首屏图片竞争主线程 —— 改为 CSS 动画或直接静态文本。`Time`（`setInterval(1000)` 永久重渲染）改为 CSS/`Intl` 一次性渲染 + 每分钟更新，或直接静态。

#### P1.4 自定义光标收窄

`style/globals.css:243-245` 的 `* { cursor: … !important }` 收窄到可交互元素；`body` 上的 `cursor`（`:163`）保留即可。此项置信度较低（R13），实施后需实测确认收益，若无收益则回退。

#### P1.5 清理死代码与幽灵依赖

- 补声明 `@radix-ui/react-visually-hidden`（或改用已有依赖替代，如 `@radix-ui/react-dialog` 内部能力）。
- 移除零引用依赖：`@heroui/react`、`@heroui/styles`、`recharts`、`react-day-picker`、`embla-carousel-react`、`vaul`、`heic2any`、`dayjs`、`date-fns`（**逐个验证后再删**，`components/ui/*` 的 shadcn 样板文件可能连带删除）。
- 删除死代码：`floating-filter-ball.tsx`、`camera-lens-filter.tsx`（连带 `default-gallery.tsx:63-89`、`simple-gallery.tsx:51-71` 中永不触发的筛选 debounce 逻辑）、`ui/carousel.tsx`、`/api/public/camera-lens-list` 路由及其查询。
- `next-pwa`：要么修好（Next 16 需要替代方案），要么连同 `next.config.mjs` 的 PWA 配置一起移除。倾向**移除**，因为当前它只是无声地什么都不做，而 `<link rel="manifest">` + `manifest.json` 已足够提供可安装性基础。
- 移除 `next.config.mjs` 中已失效的 `eslint` 键；评估关闭 `typescript.ignoreBuildErrors`（需先修完存量类型错误，可作为独立后续项）。

---

### P2 — 打破动态渲染与缓存

#### P2.1 locale 移出 `cookies()`

- 现状：`lib/utils/locale.ts:10` 用 `cookies()` 取语言，位于根 layout 的调用链上 → 全站动态。
- 目标：让公开页面（`/`、`/[album]`、`/tag/*`、`/preview/*`、`/login`、`/sign-up`、`/map`、`/rss.xml`）能够静态化或用 ISR。
- 方案（按优先级）：
  1. 用 `Accept-Language` 请求头做语言协商（`headers()` 同样会触发动态，需配合 `[locale]` 路由段或 CDN 层注入 `Vary`）。
  2. 引入 `app/[locale]/...` 路由段，语言写进路径 → 页面可静态化，CDN 可按 URL 缓存。
- 该决策影响 URL 结构与 SEO，**必须在实施前单独确认**（见第 9 节）。

#### P2.2 请求级去重与并行

- 用 React `cache()` 包装 `fetchConfigsByKeys`、`fetchAlbumsShow`、`fetchSiteBranding`，消除同一请求内的重复查询（`app/layout.tsx:24` 与 `:61`、三个 layout 各自的 `fetchAlbumsShow`）。
- `app/(default)/page.tsx:31-35`：把 config 查询并入 `Promise.all`。
- `server/db/query/images.ts:47-50`：把 `fetchConfigValue('admin_images_per_page')` 移出列表查询关键路径（页面尺寸改为常量或随请求并行取）。
- `server/db/query/images.ts:198-206`：`albums.findFirst` 与列表查询并行（或直接用 JOIN 合并）。
- `app/sign-up/page.tsx:11,16`、`app/admin/about/page.tsx:8-9`：串行 await 改 `Promise.all`。

#### P2.3 跨请求缓存

- `fetchConfigsByKeys` / `fetchSiteBranding` 加 `unstable_cache`（长 TTL + tag），配置变更时用 `revalidateTag` 失效（配置的写入口在 `server/db/operate/configs.ts`，在那里挂失效）。
- `fetchAlbumsShow` 同理（相册写入口 `server/db/operate/albums.ts`）。

#### P2.4 索引与查询形状

- 新增索引（`prisma/migrations/`，配套 migration SQL）：
  - `images_albums_relation(album_value, imageId)`
  - `images(id) WHERE del = 0 AND show = 0 AND show_on_mainpage = 0`（部分索引）
  - 可选：`images(sort DESC, created_at DESC)` 部分索引
- 把 EXIF 拍摄时间落成真实的 `captured_at timestamp` 列（迁移回填 + 上传时写入 + 应用侧读取），替代 `ORDER BY COALESCE(TO_TIMESTAMP(COALESCE(image.exif->>'data_time', …)))`，使排序可走索引。
- 所有列表查询：把 `SELECT image.*` 改为显式列清单；列表路径去掉 `exif` / `labels` 大 JSON（只有简单主题与预览页需要 exif，按视图区分）。
- `fetchMapImages`（`images.ts:308-336`）加分页或服务端聚合（否则 RSC payload 随图库增长无上限）。
- 计数查询的 `SELECT DISTINCT ON (image.id)` 改为 `COUNT(*)` + 必要的 EXISTS/JOIN 重写，配合索引。

#### P2.5 专辑页消除双段瀑布

`app/(theme)/[...album]/page.tsx` 按 `app/(default)/page.tsx:44-46` 的模式补齐 `initialImages` / `initialPageTotal` / `initialConfigData`，`Promise.all` 并行取。

#### P2.6 响应缓存头

- `/rss.xml` 加 `revalidate`（当前无任何缓存头）。
- 公开页面在 P2.1 之后按静态/ISR 产出，并确认 Cloudflare 对 HTML 的缓存策略（`s-maxage` / `CDN-Cache-Control`）。

---

### P3 — 渲染与打包

#### P3.1 代码分割

- `app/(theme)/[...album]/page.tsx`：三种画廊改为 `next/dynamic`，按 config 只加载命中的那一种。
- `components/album/progressive-image.tsx:8`：`WebGLImageViewer` 改 `next/dynamic`（当前 2,140 行永不可达）。
- `components/layout/theme/map/map-view.tsx`：`react-map-gl/maplibre` 保持现状（已懒加载），核对确认。
- 后台：`heic-to` + `exifreader` 拆分（`lib/utils/file.ts:1` 的 `exifreader` 改 `await import`；`heic-to` 在三个上传组件里改按需）；`emblor`、`compressorjs` 同理。目标把 `/admin/upload` 首屏从 4.0 MB 压到 < 1 MB。
- 排查 `motion` 被打进两个 chunk 的原因（重复依赖或版本分裂），确保只留一份。
- 复核 `next.config.mjs`：考虑加 `experimental.optimizePackageImports`（针对 `animal-island-ui`、`lucide-react`、`motion`）。

#### P3.2 Tooltip 收敛

`components/gallery/simple/gallery-image.tsx` 的 9 个 Tooltip/方块：

- EXIF 行（`:226,234,242,250,258`）改为原生 `title=` 属性或单一容器级 hover 卡片。
- 操作行（`:299,311,325,332`）同理。
- 目标：每方块 DOM 节点从 ~130 降到 < 20。

#### P3.3 重渲染治理

- `components/layout/dock-menu.tsx:16`、`components/layout/command.tsx:25-27`：`useButtonStore((state) => state)` 改为细粒度 selector。
- `components/ui/origin/infinite-scroll.tsx:23-38`：`next` 存入 `useRef`，deps 只留 `hasMore`/`isLoading`；调用方改 `useCallback`。
- `default-gallery.tsx:139-147`、`tag-gallery.tsx:87-94`：`photos` 与 `render` 用 `useMemo`/模块级常量；给每张 photo 加 `key: item.id`（库当前回落 `index`）。`blur-image.tsx` 加 `memo`。
- `map-view.tsx:73-79,114`：`onMove` 节流到 ~200ms，把 `zoom` 移出 cluster 依赖或把聚类移出 React。
- `draggable-card.tsx:68-98`：把约束计算提升到容器级单个 `ResizeObserver`；`onMouseMove` 不再逐次 `getBoundingClientRect()`（用 pointer 相对坐标）。

---

## 7. 验收标准

全部为可复现的测量，不依赖主观判断。

### 7.1 构建产物

- [ ] 首屏 JS ≤ 200 KB gzip（当前 357.4 KB）
- [ ] 全局 CSS 原始 ≤ 80 KB（当前 483.4 KB），且产出 CSS 中不含 `number-field` / `.toast` / `.accordion`
- [ ] 产出中不存在 `noto-sans-sc-chinese-simplified-*.woff2`（1.1 MB 级文件）
- [ ] `motion` 只存在于一个 chunk
- [ ] `/admin/upload` 首屏 JS ≤ 1,000 KB（当前 4,040 KB）
- [ ] `next build` 在 **pnpm 严格安装**下通过（不需要 node_modules 手工符号链接）

### 7.2 网络与运行时（对生产或等价环境）

- [ ] TTFB ≤ 0.5 s（当前 2.4 s）
- [ ] 首页 HTML ≤ 150 KB（当前 802 KB）
- [ ] 首屏图片总字节 ≤ 2 MB（当前 118.5 MB）
- [ ] 单张网格图解码像素 < 0.2 MP，且每方块只解码一层
- [ ] 对同一图片 URL 第二次请求 `cf-cache-status: HIT`
- [ ] 中文页面实际下载字体 ≤ 150 KB
- [ ] 首次加载无固定时长遮罩；客户端跳转无固定时长遮罩
- [ ] 滚动 5 页（120 张）后 `document.getElementsByTagName('*').length` 不随页数线性增长（虚拟化生效）
- [ ] 一次预览打开对同一张图的网络请求数 ≤ 1
- [ ] 滚动期间无 > 50ms 的 Image Decode 长任务

### 7.3 正确性

- [ ] 中文字形与现状像素级一致（截图对比 400/500/700 三档）
- [ ] 无限滚动不重复、不漏图（当前 `LIMIT` 后随机排序导致重复/漏图）
- [ ] 图片方向正确（EXIF orientation 应用），DB 宽高与文件一致
- [ ] 上传新图后 `preview_url` 自动为 ≤ 400px 的 webp，无需人工干预
- [ ] 现有 39 张图片迁移后全部满足同一约束
- [ ] 三种画廊主题、标签页、地图页、预览页、后台 CRUD 全部功能不回归

---

## 8. 风险与回滚

| 风险 | 缓解 | 回滚 |
|---|---|---|
| 历史数据迁移写坏 `preview_url` | 先 dry-run 报告 → 人工确认 → `--apply`；迁移前导出 `images` 的 `id,url,preview_url,width,height` 快照 | 按快照还原 |
| 服务端缩略图改变观感（webp 有损） | 先在一张图上做质量对比（q72/q78/q80）确认可接受再全量 | 保留原图，降低质量参数或回到 JPEG |
| P2.1 locale 改 URL 结构影响 SEO | 实施前单独确认方案；保留现有 cookie 语言作为覆盖 | 回退为 cookie 方案（即回到动态渲染） |
| 字体剥离 PostCSS 步骤误删样式 | 只匹配 `src` 指向 `files/noto-sans-sc-*` / `files/nunito-*` 的 `@font-face`；构建后 diff 其余 CSS | 撤掉该 PostCSS 步骤 |
| 去掉 GSAP 过场后"少了品牌感" | 已获视觉授权；保留纯 CSS 备选 | 恢复组件（但保留去除最小显示时间） |
| 虚拟化引入滚动/锚点回归 | 分主题独立开关，先 simple 主题灰度 | 关掉虚拟化开关 |
| Cloudflare Cache Rule 误缓存动态内容 | 只对资产域、`/_next/static`、`/_next/image` 与图片代理加规则；HTML 走 P2.1 的显式策略 | 删除 Cache Rule |
| 删依赖导致构建失败 | 每个依赖独立删除 + 构建验证；一次一个 | 恢复 `package.json` 条目 |

---

## 9. 未决项（实施前需确认或需实测）

1. **P2.1 的语言方案**（`Accept-Language` 协商 vs `[locale]` 路由段）——影响 URL 结构与 SEO，需用户单独拍板。
2. **`/[album]` 的实际 `pageTotal`**（当前图库仅 39 行，收益会随增长放大）。
3. **生产回源位置**（Cloudflare Containers / Workers / VPS）——决定 Prisma 连接与缓存手段；用户已完成 `wrangler login` 后需核对。
4. **`@fontsource` 覆盖 vs PostCSS 剥离**哪条路在生产构建下确定生效——必须实测，不接受推断。
5. **`tone-analysis`/`histogram-chart` 的 `_t=` 分支是否在生产实际触发**（取决于 `preview_url` 是否与站同源）。
6. **`typewriter`/`Time`/`bounce` 等动效的保留边界**——P1.3 涉及观感，需在计划评审时逐项确认。

---

## 10. 计划分解（范围自审结论）

本设计的范围**超出单个实施计划**应承载的粒度：它跨 4 个阶段、约 40 个文件、含一次数据迁移与一次 Cloudflare 配置变更。因此不作为一份计划实施，而是**一个设计文档 → 四份独立计划**，每份计划独立产出可运行、可验证的软件：

| 计划 | 内容 | 依赖 |
|---|---|---|
| `plan-1-image-pipeline` | P0 全部（含迁移脚本、上传流程改写、CF Cache Rule） | 无 |
| `plan-2-dead-weight` | P1 全部 | 无（可与 plan-1 并行） |
| `plan-3-rendering-cache` | P2 全部 | 需先确认第 9 节第 1 项（语言方案） |
| `plan-4-bundle-rerender` | P3 全部 | 无 |

**建议执行顺序**：plan-1 → plan-2 →（确认语言方案后）plan-3 → plan-4。plan-1 与 plan-2 之间无共享文件（图片管线 vs CSS/字体/依赖），可并行；plan-3 的 `Promise.all` 与缓存改动会触碰 `app/layout.tsx`，plan-4 会触碰画廊组件，因此这两份必须串行在 plan-1 之后。

每份计划完成后必须独立通过其对应阶段的验收项（第 7 节），再进入下一份。

## 11. 交付物

- 本设计文档：`docs/superpowers/specs/2026-10-03-performance-design.md`
- 实施计划（本设计通过后由 `writing-plans` 逐份产出）：
  - `docs/superpowers/plans/2026-10-03-plan-1-image-pipeline.md`
  - `docs/superpowers/plans/2026-10-03-plan-2-dead-weight.md`
  - `docs/superpowers/plans/2026-10-03-plan-3-rendering-cache.md`
  - `docs/superpowers/plans/2026-10-03-plan-4-bundle-rerender.md`
- 迁移脚本：`scripts/migrate/regenerate-previews.ts`
- 新增服务端能力：`server/lib/thumbnail.ts`
- 新增 Prisma migration（索引 + `captured_at` 列）

---

## 12. 实施后的实测结果（2026-10-03）

以下全部为实施后**重新测量**的数值，不是估算。与估算不符的地方已在上文对应根因处标注修正。

### 12.1 首屏 / 关键路径

| 指标 | 实施前 | 实施后（实测） | 变化 |
|---|---|---|---|
| **首屏图片字节** | 122.78 MB | **1.17 MB** | **−99.0%** |
| 单张网格图解码像素 | 12.2 MP（×2 层） | 800×600（×1 层） | −96% |
| 网格 `src` 指向原图 | 24 / 24 | **0 / 24** | 全部改为缩略图 |
| 网格 `<img>` 元素数 | 40 | 24 | HD 图层消除 |
| 每方块 DOM 节点 | **138** | **36** | **−74%** |
| 首页 HTML 元素总数 | 3,311 | 852 | −74% |
| ClipPath / SVG 数 | 657 / 439 | 9 / 6 | −98.6% |
| 首页 HTML 字节 | 802 KB | 289 KB | −64% |
| **TTFB（热）** | 2.4 s | **0.015 s** | **−99.4%** |
| TTFB（冷，缓存未命中） | 2.4 s | 2.2 s | 持平 |

TTFB 的实现方式：`unstable_cache` 覆盖 configs / albums / 画廊列表与总数（tag 失效 + 60/300s TTL），并用 `Promise.all` 消除串行查询。冷路径仍需一次真实 DB 往返。

### 12.2 产物体积

| 指标 | 实施前 | 实施后（实测） | 变化 |
|---|---|---|---|
| 全局 CSS（raw） | 483.6 KB | 477.2 KB | 净 −6.4 KB |
| — 其中 HeroUI 死代码 | — | — | **−303.6 KB**（实测 A/B） |
| — 其中字体分片声明 | — | — | +297.2 KB（代价） |
| 全局 CSS（gzip） | ~63 KB | 129.5 KB | +66 KB（字体分片代价） |
| 中文字体下载 | 3,391.6 KB | 1,665.6 KB | **−1,726 KB** |
| 首页 JS（raw / gzip） | 1119.7 KB / 357.4 KB | **1032.0 KB / 320.2 KB** | −87.7 / −37.2 KB |
| `/admin/upload` JS | 4,040.4 KB | **1,198.8 KB** | **−70.3%** |
| 人为阻塞（首屏 / 跳转） | 1000 / 700 ms | **0 / 0** | 消除 |

### 12.3 与估算不符之处（诚实记录）

1. **首屏图片「省 82.73 MB」不准确**。Task 1 实测只省 54.23 MB（122.78→68.55 MB），因为 8 张照片的 `preview_url` 是**空字符串**（不是 NULL），仍回退到原图。真正的 −99% 是 P0.1–P0.3 缩略图管线完成后才达到的。
2. **字体收益 3.2 MB 是错的**。Noto Sans SC 的 101 个分片按**码点**切分、不按使用频率，实测每字重仍要下约 550 KB（命中 18/101 个分片），实际只省 1.73 MB，并让渲染阻塞 CSS 的 gzip 上升约 66 KB。更优方案（按频率做自定义子集）见 R8。
3. **CF「一个字节都没缓存」是错的**。早期用 `HEAD` 测量，而 **Cloudflare 不缓存 HEAD 请求**。改用 GET 后实测资产域与 `/_next/static` 都是 HIT；问题只在无扩展名的 `/api/public/url-proxy` 不可缓存。
4. **画廊三选一的代码分割收益极小**。Turbopack 把 `simple-gallery` 与 `blur-image`（default 主题）合并进同一个 chunk，仅 polaroid / WebGL / heic-to / exifreader 被移出。首页 JS 只降了约 1 KB；代码分割的真实收益落在 `/admin/upload`（−70%）。

### 12.4 明确的未完成项与理由

| 项 | 状态 | 理由 |
|---|---|---|
| P1.4 收窄自定义光标 | **不做** | spec 自评为低置信度且条件于「实测有收益」；无法在无浏览器 profile 的情况下量出合成器开销，而它会**可见地**改变外观。做无法验证收益的外观改动属于猜测。 |
| P2.1 locale 移出 `cookies()` → 静态渲染 | **不做（待用户决策）** | 数据缓存层已把 TTFB 从 2.4s 降到 0.015s，**已超出 spec 的 <0.5s 目标**；而剩余两种做法各有代价：`Accept-Language` 协商需配合 `[locale]` 路由段或 CDN 注入 `Vary`（改 URL 结构、影响 SEO），或把语言读取限制在 admin 段（改变站主自己浏览公开页的语言行为）。收益边际化而代价明确，应由用户拍板。 |
| P0.6 网格虚拟化 | **暂缓（仅修了分页正确性 bug）** | 支撑虚拟化的前提已改变：每方块 DOM 138→36、单图 4.85 MB→28 KB。240 张时约 8.6k 节点、6.7 MB 图片，已不构成瓶颈。虚拟化会改变滚动行为（回滚位置、瀑布流重排）并带来回归风险。这是基于实测的取舍，不是遗漏。 |
| P2.4 `captured_at` 真实列 | **暂缓** | `exif->>'data_time'` 上的派生排序仍不可索引，但 60 秒数据缓存已消化绝大多数请求；把拍摄时间落成真实列需要「加列 + 回填 + 改写入路径 + 改查询」四步，收益边际。已建的部分索引覆盖了可见性 + sort/created_at 部分。 |

### 12.5 交付的改动（按提交顺序）

| 提交 | 内容 |
|---|---|
| `cb5959f` | 设计文档 |
| `a6e020c` | 移除 HeroUI 死 CSS（−303.6 KB） |
| `84ae64b` | 网格不再预加载并叠加原图（−54.23 MB） |
| `77e9d1c` | 图片直连资产域，摘除不可缓存的代理路径 |
| `f090ef7` | 中间件放行图片与静态资源路径 |
| `ab8680f` | 声明幽灵依赖 `@radix-ui/react-visually-hidden`（修复严格安装下的构建失败） |
| `c764056` / `03a0a7d` | 中文字体 unicode-range 分片（−1.73 MB）+ 构建期防线 |
| `381a5e2` | 移除 GSAP 全屏遮罩（−37.2 KB gzip、−700/1000ms） |
| `d7c98d4` | 服务端 sharp 缩略图 + 39 行历史迁移（−99% 首屏图片） |
| `6ebffac` | 去 Tooltip 改原生 title（DOM −74%）、首批 priority、预览页去缓存破坏、修复分页随机排序 |
| `1f5527b` | 代码分割（`/admin/upload` −70%） |
| `eb01904` | 数据缓存层 + 3 个索引（TTFB 2.21s→0.015s） |
| 最后一项 | 相册/标签页瀑布流可 SSR（此前首屏瓦片数为 0） |

### 12.6 生产数据变更记录

- **图片缩略图迁移**：39/39 行成功、0 失败。原图合计 134.52 MB → 缩略图 1.92 MB（压缩 98.6%）。回滚快照：`scripts/migrate/backups/regenerate-previews-2026-10-03T12-10-27-103Z.json`。
- **新增索引 3 条**（已通过 `prisma migrate deploy` 应用并验证）：`images_albums_relation_album_value_imageId_idx`、`images_visible_sort_created_idx`、`images_labels_gin_idx`。
- **一次失败的迁移已按流程处理**：首次 `images_labels_gin_idx` 因 `labels` 列真实类型是 `json`（非 jsonb）报 42704，事务回滚（0/3 索引）；修正为表达式索引 `((labels)::jsonb)` 后 `migrate resolve --rolled-back` + 重新 `deploy`，最终 3/3 成功。
- **未部署**：以上改动均只落在本地 git，生产 `felina.boxz.dev` 仍是旧版本，需要一次部署才能生效。
