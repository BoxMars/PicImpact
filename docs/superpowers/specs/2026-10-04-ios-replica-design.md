# iOS 1:1 复刻设计文档（PicImpact / 大福映画 Felina Gallery）

- **日期**：2026-10-04
- **目标**：用原生 iOS（SwiftUI）1:1 复刻现有 Web 站点
- **被复刻对象**：`https://felina.boxz.dev`（Next.js 16 App Router + Hono + Prisma + R2）
- **文档性质**：设计规格（spec）。所有"现状"结论均来自仓库代码与生产实测，未核实之处显式标注。

---

## 0. 这份文档要解决什么

复刻的难点不在画界面，而在三件事：

1. **列表数据目前没有公开接口**（§2）。这是唯一的硬阻断项，必须先解决才能开工。
2. **"1:1" 的边界需要提前划清**（§3）。有些东西（WebGL 查看器、maplibre 地图、EXIF 解析）在 iOS 上应当用原生替代 —— 结果一致但实现不同；另有一些（自定义光标、hover、⌘K）本质上无法复刻。
3. **视觉规格必须落到数字**（§5、§6）。否则"看着像"会在几十个屏幕上逐渐跑偏。

---

## 1. 现状基线

### 1.1 技术栈与部署

| 项 | 值 |
|---|---|
| 框架 | Next.js 16.1.6（App Router、Turbopack）+ React 19.2.4 |
| 后端 API | Hono，挂在 `/api`（`app/api/[[...route]]/route.ts`，`runtime = 'nodejs'`） |
| ORM / 数据库 | Prisma 6.4.1 → Postgres（Supabase，东京 `ap-northeast-1`，pgbouncer 6543） |
| 对象存储 | Cloudflare R2，bucket `felina-image`，目录 `images` |
| 公开资产域 | `https://felina-asset.boxz.dev`（`access-control-allow-origin: *`） |
| 鉴权 | better-auth（cookie 前缀 `pic-impact`，支持 Passkey / 两步验证） |
| 部署 | Vercel（源站）← Cloudflare（代理/CDN） |

### 1.2 页面清单与 URL 结构

| URL | 文件 | 说明 |
|---|---|---|
| `/` | `app/(default)/page.tsx` | 首页画廊（风格由配置决定，见 §1.3） |
| `/preview/[...id]` | `app/(default)/preview/[...id]/page.tsx` | 图片预览详情 |
| `/tag/[...tag]` | `app/(default)/tag/[...tag]/page.tsx` | 按标签浏览 |
| `/[...album]` | `app/(theme)/[...album]/page.tsx` | 相册页（`album_value` 形如 `/daily`） |
| `/map` | `app/(theme)/map/page.tsx` | 地图页（有 GPS 的图片） |
| `/login`、`/sign-up` | `app/login`、`app/sign-up` | 登录 / 注册（注册仅首个用户可用） |
| `/admin/*` | `app/admin/**` | 后台：上传、列表、相册、配置、账户、Passkey、存储 |

**iOS 端必须复刻的是前 6 组（公开面）。** `/admin/*` 是否纳入见 §7 阶段划分。

### 1.3 主题系统：两套正交的"主题"

这是最容易复刻错的地方 —— 站点有**两套互不相关**的主题选择：

**A. 首页风格**（全局配置 `custom_index_style`）

**B. 相册风格**（`Albums.theme` 字段，逐相册）

两者取值映射一致（`app/(theme)/[...album]/page.tsx:90`）：

| 取值 | 主题组件 | 视觉特征 |
|---|---|---|
| `'1'` | `components/layout/theme/simple/simple-gallery.tsx` | 岛屿风纸卡 + 行优先瀑布流 + 卡片下方信息块（当前生产值） |
| `'2'` | `components/layout/theme/polaroid/polaroid-gallery.tsx` | 拍立得：固定宽度卡片、确定性错落位置（`hashToUnit(id, salt)`） |
| 其他 / `'0'` | `components/layout/theme/default/default-gallery.tsx` | `react-photo-album` 的 `MasonryPhotoAlbum`，纯图无信息块 |
| — | `components/layout/theme/map/map-view.tsx` | 地图，用于 `/map` |

> 生产实测：首页 `custom_index_style = 1`（simple），相册 `/daily` 的 `theme = 0`（default）。
> **即首页与相册页目前是两种不同风格**，iOS 端两套都要做。

### 1.4 数据模型（`prisma/schema.prisma`）

```
Images
  id                 String  @id @default(cuid())
  image_name         String?
  url                String?      // 原图
  preview_url        String?      // 800px 缩略图（webp）
  video_url          String?      // Live Photo 的视频
  blurhash           String?
  exif               Json?        // 原始 EXIF（exifreader 的解析结果）
  labels             Json?        // 标签数组
  width, height      Int
  lon, lat           String?      // 地图用
  title, detail      String?
  type               Int          // 1 = 普通图片；非 1 = Live Photo
  show               Int          // 0 = 公开，1 = 私有（注意是反的）
  show_on_mainpage   Int          // 0 = 上首页
  sort               Int
  createdAt/updatedAt
  del                Int          // 0 = 未删除

Albums
  id, name, album_value(@unique), detail
  theme              String       // '0' | '1' | '2'
  show, sort, random_show, image_sorting
  license            String?

ImagesAlbumsRelation    // (imageId, album_value) 复合主键，多对多

Configs                 // config_key(@unique) / config_value / detail
User / TwoFactor / Session / Account / Verification / Passkey   // better-auth
```

**iOS 端要注意的语义坑**：`show = 0` 才是公开、`del = 0` 才是未删除 —— 与直觉相反，DTO 层务必写测试固定住。

### 1.5 HTTP 接口清单

前缀 `/api`，由 `app/api/[[...route]]/route.ts` 挂载。**鉴权边界在 `proxy.ts`：`/api/v1/*` 必须有会话 cookie**。

**公开（无需鉴权）** —— iOS 端目前只能靠这三个：

| 方法 | 路径 | 返回 |
|---|---|---|
| GET | `/api/public/images/get-image-by-id?id=` | 单张公开图片的完整数据 |
| GET | `/api/public/images/get-image-blob?imageUrl=` | 服务端代为抓取图片字节（用于绕过跨域） |
| GET | `/api/public/download/:id?storage=` | 原图下载（带 `Content-Disposition`） |

**需鉴权（`/api/v1/*`）**：

```
albums    GET /get   POST /add   PUT /update   DELETE /delete/:id   PUT /update-show
images    POST /add  PUT /update  PUT /update-show  PUT /update-Album
          DELETE /delete/:id   DELETE /batch-delete
file      POST /presigned-url   POST /upload   POST /getObjectUrl
settings  GET /get-custom-info  GET /get-admin-config  GET /r2-info  GET /s3-info
          PUT /update-custom-info  PUT /update-r2-info  PUT /update-s3-info  PUT /update-open-list-info
storage   GET /storage/open-list/info   GET /storage/open-list/storages
```

### 1.6 图片管线

- **上传时**由服务端 `sharp` 生成缩略图：`server/lib/thumbnail.ts`（`.rotate()` 自动转正、最长边 800、webp q76，**不**回退 PNG/JPEG），再上传 R2 并设 `Cache-Control: public, max-age=31536000, immutable`。
- 缩略图 URL 是内容哈希（cuid）命名，不可变。实测一次迁移把 39 张原图从 **134.52 MB → 1.92 MB**（−98.6%）。
- 前端取图优先级：`preview_url || url`。预览页先显示 800px 缩略图，再交叉淡入（0.6s opacity）原图。
- 生产当前用 `next/image` 走 Vercel 优化器（`sizes` 按实际布局给出）→ **iOS 端与此无关，直接下载 `preview_url` / `url` 即可**。

### 1.7 设计令牌（从代码统计出的实际用色）

| 用途 | 值 | 出现次数 |
|---|---|---|
| 主强调色（进度条、选中、岛屿描边高亮） | `#19c8b9` | 13 |
| 卡片边框 / 纸张描边 | `#c4b89e` | 11 |
| 纸张色 | `#f0ece2` | 8 |
| 页面背景 | `#f8f8f0` | 6 |
| 次级文字（label） | `#9f927d` | 6 |
| 主文字（value） | `#725d42` | 6 |
| 卡片投影（硬阴影层） | `#bdaea0` | 5 |
| 深棕（标题/描边） | `#794f27` / `#6a5535` / `#4a3928` / `#5a4530` | 3 / 3 / 3 / 2 |
| 浅青（选中底） | `#82d5bb` / `#e6f9f6` | 4 / 2 |
| 标签/分类色 | `#f8a6b2` `#f7cd67` `#e59266` `#e05a5a` `#889df0` | 各 2 |

**岛屿卡（simple 主题的核心视觉）**，取自 `gallery-image.tsx` 的实际内联样式：

```
border-radius     18
background        rgb(247, 243, 223)
border            2px solid #c4b89e
box-shadow        0 3px 0 0 #bdaea0, 0 4px 16px rgba(121,79,39,0.08)
transition        box-shadow .25s ease, transform .25s ease
contain           layout style
```

（注意是**硬阴影 + 柔阴影双层**：`0 3px 0` 造出"贴纸厚度"，是这套视觉的关键，iOS 需用两个 shadow 叠加还原。）

### 1.8 字体

```
font-family: Nunito, 'Noto Sans SC', -apple-system, 'PingFang SC', sans-serif
字重：Nunito 500 / 700 / 900 ；Noto Sans SC 400 / 500 / 700
```

两者均为 OFL 授权，**可直接打包进 App**。注意 Noto Sans SC 全量体积大 —— Web 端已改用 `unicode-range` 分片按需加载，iOS 端建议**子集化后打包**，或直接回退系统苹方并接受字形差异（见 §3.3）。

### 1.9 国际化

- 语言包：`messages/{zh,en,ja,zh-TW}.json`，共 **365 个 key**
- 命名空间：`Words` `Login` `Link` `Passkey` `Tips` `Button` `Dashboard` `Upload` `List` `Album` `Preferences` `Password` `Account` `Config` `Command` `Theme` `Filter` `Exif`

iOS 端直接用 **String Catalog（`.xcstrings`）**，从这四个 JSON 生成即可（建议写个一次性脚本，别手抄）。

### 1.10 关键交互与动效（决定"像不像"的部分）

| 交互 | Web 实现 | 备注 |
|---|---|---|
| 瀑布流 | 行优先 CSS Grid + 逐项实测高度设 `grid-row-end: span N`（粒度 8px、间距 16px） | iOS 用 `Layout` 协议或自算 frame |
| 首屏优先级 | 前 4 张 `fetchPriority=high`，其余 lazy | iOS 用预取 |
| 无限滚动 | `InfiniteScroll` 组件 + 分页（服务端 action 取下一页） | |
| 预览交叉淡入 | 缩略图 → 原图，0.6s opacity | |
| 全屏缩放查看 | **自研 WebGL 查看器**（`components/album/webgl-viewer/`，含 shader 与 texture worker） | iOS 用原生缩放，见 §3.2 |
| 进度条 | 顶部 3px，`#19c8b9` | iOS 用自定义 overlay |
| 命令菜单 | ⌘K（`Command` 命名空间） | **无法复刻**，见 §3.3 |
| 地图 | `maplibre-gl` + `react-map-gl`（Marker/Popup/Navigation/Scale/Geolocate/Fullscreen） | iOS 用 MapKit |
| Live Photo | `video_url` + 视频播放 | iOS 有原生 Live Photo |
| 影调分析 | canvas `getImageData` + 自算 | iOS 用 CoreImage，更准 |
| 直方图 | canvas 256 bin × 4 通道（红/绿/蓝/亮度），弹簧动画 | iOS 用 CoreImage + SwiftUI Canvas |

---

## 2. ⚠️ 阻断项：列表数据没有公开接口

### 2.1 事实

`proxy.ts:8`：

```ts
if (request.nextUrl.pathname.startsWith('/api/v1') && !sessionCookie) {
  return Response.json({ success: false, message: 'authentication failed' }, { status: 401 })
}
```

而相册列表、图片列表、标签列表**全部是服务端渲染时直接调 Prisma 查询得到的**（`server/db/query/{albums,images}.ts`），**没有对应的 HTTP 接口**。公开的三个接口里：

- `get-image-by-id` 只能取**单张**（已知 id 时）
- `get-image-blob` 只是图片字节代理
- `download` 只能下载

**结论：iOS 端目前无法获取"首页/相册/标签有哪些图"。** 这必须先解决。

### 2.2 三个方案

| 方案 | 做法 | 代价 | 评价 |
|---|---|---|---|
| **A. 新增公开只读接口**（建议） | 在 Web 端加 `GET /api/public/gallery?album=&tag=&page=&size=`，复用现有 `fetchClientImagesListByAlbum` 等查询与 `unstable_cache` 缓存 | 约 1 个文件、~80 行；不触碰现有鉴权边界 | **推荐**。改动最小、语义清晰、可直接复用已做好的缓存与索引 |
| B. 复用 `/api/v1/*` | iOS 内登录管理员，用需鉴权接口 | 等于把管理员凭据放进 App；且 `/v1` 无分页列表接口 | 不接受 |
| C. 解析 SSR 输出 | 抓 HTML / RSC payload | 无契约、任何前端改动都会打断 | 不接受 |

**方案 A 的接口草案**（建议在 iOS 开工前先落地并冻结）：

```http
GET /api/public/gallery?album=%2Fdaily&page=1&size=24
→ 200 { code, message, data: { list: ImageDTO[], total: number, page: number, hasMore: boolean } }

GET /api/public/albums
→ 200 { code, message, data: AlbumDTO[] }          // 仅 show=0 且 del=0

GET /api/public/tags
→ 200 { code, message, data: string[] }

GET /api/public/config
→ 200 { code, message, data: { custom_title, custom_author, custom_logo_url,
        custom_index_style, custom_index_download_enable, custom_index_origin_enable } }
```

`ImageDTO` 建议只暴露客户端需要的字段（**不要直接回 Prisma 实体**）：`id, url, preview_url, video_url, blurhash, width, height, title, detail, type, labels, lon, lat, exif, createdAt`。

---

## 3. "1:1" 的判定标准

### 3.1 必须逐项一致（硬要求）

1. 所有公开页面的**信息结构与层级**
2. 设计令牌（§1.7 的颜色、圆角、双层阴影）
3. 岛屿卡的几何与"贴纸厚度"阴影
4. 瀑布流的**行优先顺序**与参差高度
5. 图片宽高比永不被裁切（`object-fit: contain`/等比）
6. 文案（365 个 key 的取值）
7. `show=0` / `del=0` 的过滤语义
8. 三种画廊风格与相册级主题选择
9. 预览页的 EXIF / 影调 / 直方图 / 下载 / Live Photo 功能集

### 3.2 结果一致、实现必然不同（原生替代）

| 能力 | Web | iOS |
|---|---|---|
| 缩放平移查看 | 自研 WebGL 查看器 | `UIScrollView` 缩放 或 SwiftUI `MagnifyGesture` + `DragGesture` |
| 地图 | maplibre-gl | MapKit（`Map` + `Annotation`），或 MapLibre Native 若要同款底图 |
| EXIF 解析 | `exifreader`（客户端） | `CGImageSourceCopyPropertiesAtIndex`（服务端已有 `exif` JSON，直接用） |
| HEIC 转换 | `heic-to`（客户端 JS） | 系统原生解码，**不需要** |
| 图片解码 | 浏览器 | ImageIO + `AsyncImage`/Kingfisher |
| 影调/直方图 | canvas 手算 | CoreImage `CIAreaHistogram`，更准更快 |
| 毛玻璃 | `backdrop-blur` | `UIVisualEffectView` / `.ultraThinMaterial` |

### 3.3 无法复刻（诚实列出）

| 项 | 原因 | 处理 |
|---|---|---|
| 自定义光标（`island-cursor`） | 触屏无 hover 概念 | 直接不做 |
| hover 态 | 同上 | 改成 `pressed` / 长按反馈 |
| ⌘K 命令菜单 | 桌面键盘交互 | 可选：用 iOS 26 的 `TabView` 搜索栏替代，**但要标注这不是 1:1** |
| 顶部 3px 进度条 | 浏览器导航语义 | 用 `ProgressView` 做等价反馈；或不做 |
| 字体逐字形一致 | 苹方 vs Noto Sans SC 字形不同 | 子集化打包 Noto Sans SC 才能完全一致（体积换保真） |
| `blurhash` 占位 | 需要 blurhash 解码器 | iOS 有 Swift 实现（`BlurHashKit`），可做到一致 |

---

## 4. iOS 架构设计

### 4.1 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| UI | SwiftUI | 与声明式布局 + `Layout` 协议天然契合瀑布流 |
| 最低版本 | iOS 17 | 需要 `Layout` 协议、`MagnifyGesture`、`ContentUnavailableView` |
| 并发 | Swift Concurrency（`async/await` + `actor`） | |
| 网络 | `URLSession` + `Codable`，手写轻量 client | 只有 4~6 个接口，无需引入 Moya/Alamofire |
| 图片 | `AsyncImage` 起步；需要磁盘缓存/预取时换 **Kingfisher** 或自写 `actor ImageCache` | 画廊重度用图，缓存是关键 |
| 状态 | `@Observable`（Observation 框架） | iOS 17+ |
| 本地库 | SwiftData（收藏/最近浏览）或 `UserDefaults`（轻量） | 视需求 |

### 4.2 分层

```
PicImpactKit/                     Swift Package，与 App 分离，便于测试
  Networking/   APIClient、Endpoint、错误映射
  Models/       ImageDTO / AlbumDTO / SiteConfig（Codable，与 §2.2 契约一一对应）
  Repository/   GalleryRepository、AlbumRepository、ConfigRepository
  Cache/        ImageCache（内存 NSCache + 磁盘 LRU）、DTOCache
App/
  Features/     Home / Album / Tag / Preview / Map / Auth
  DesignSystem/ Color+Tokens、Font+Tokens、IslandCard、MasonryLayout
```

**关键：`Models/` 必须与 §2.2 的 DTO 契约严格对齐，并配契约测试**（同一份 JSON fixture 在 Web 与 iOS 两侧都跑），否则后端改字段会静默崩。

### 4.3 导航映射

| Web | iOS |
|---|---|
| `/` | `HomeView`（Tab 1） |
| `/[...album]` | `AlbumView(albumValue:)` push |
| `/tag/[...tag]` | `TagView(tag:)` push |
| `/preview/[...id]` | `PreviewView(id:)` push；也可用 `.sheet` 复刻 `@modal` 拦截路由的体验 |
| `/map` | `MapView`（Tab 2） |
| `/login`、`/sign-up` | `AuthView`（Tab 3 或 sheet） |

Web 端的 `app/@modal/(...)preview/[id]` 表示**预览还能以模态覆盖在列表之上** —— iOS 建议同时实现 push 与 sheet 两条路径以保持行为一致。

### 4.4 网络层

```swift
struct ImageDTO: Codable, Identifiable, Hashable {
    let id: String
    let url: String?
    let previewURL: String?      // CodingKeys: preview_url
    let videoURL: String?
    let blurhash: String?
    let width: Int
    let height: Int
    let title: String?
    let detail: String?
    let type: Int                // 1 = 图片，非 1 = Live Photo
    let labels: [String]?
    let lon: String?
    let lat: String?
    let exif: EXIF?
    let createdAt: Date
}
```

要点：
- `lon`/`lat` 在数据库里是 **String**（不是 Double），保留为 `String?` 再在展示层解析，避免解码失败。
- `exif` 是自由 JSON，**用 `EXIF` 结构体只解需要的字段**（`data_time`、`model`、`focal_length`、`f_number`、`exposure_time`、`iso`、`lens_model`），其余忽略；未知字段不能导致整页失败。
- 日期用 `ISO8601DateFormatter` 并配置 `dateDecodingStrategy`。

### 4.5 图片加载与缓存

三级策略：

1. **内存**：`NSCache<NSString, UIImage>`，按图片字节数计费（画廊场景建议上限 64~128 MB）。
2. **磁盘**：LRU，上限 300 MB~1 GB，自定义 `URLCache` 或 Kingfisher 的 `DiskStorage`。
3. **网络**：**必须先请求 `preview_url`（800px）渲染，再后台拉 `url` 原图** —— 这是 Web 端的行为（交叉淡入），也是体感的关键。

因为资产域返回 `Cache-Control: immutable` 且 URL 内容哈希命名，磁盘缓存可以**永不失效**，无需为换图做处理（换图必然换 URL）。

### 4.6 瀑布流布局（iOS 侧的核心算法）

复刻 Web 端的行优先规则，**不要**用"填最短列"的经典瀑布流（那会改变顺序）：

```
输入：items（顺序即服务端返回顺序）、列数 C、列宽 W、间距 G
行高粒度 R = 8（与 Web 一致，保证空隙观感相同）

对每个 item 依次：
  目标高度 H = W * (item.height / item.width) + 信息块高度
  span = ceil(H / R) + ceil(G / R)
  在行优先扫描顺序里找第一个「能容纳 span 行且空闲」的位置放置
  游标只向前推进（不复用已扫过的空洞）—— 这是保证顺序与 Web 一致的关键
```

信息块（标题/日期/EXIF/标签/操作）高度**必须实测或按文案行数预估**并计入 `H`；Web 端是用 `ResizeObserver` 实测的。建议 iOS 先用固定高度 + 最多两行标题截断，把不可控因素收敛掉。

### 4.7 并发与预取

- 首屏：前 4 张走最高优先级下载（对应 Web 的 `fetchPriority=high`）
- 滚动停稳后预取下一页（对应 InfiniteScroll）
- 用 `Task` + `TaskGroup` 限制并发为 4~6，避免打满连接池

---

## 5. 逐屏规格

> 以下尺寸均直接从代码读取，单位 px（iOS 用 pt 时按 1:1 处理，注意 Web 的 1px 在 3x 屏上是 1pt）。

### 5.1 首页（三种风格）

**simple（生产当前风格）**

```
容器：maxWidth 1280，居中；左右内边距 12 / 24 / 40（sm / md 断点）
      上下内边距 16
网格：1 列（<640）/ 2 列（640–1024）/ 3 列（≥1024）
      列间距 16，行间距 16
卡片：见 §1.7 岛屿卡
      内含 GalleryImage = 图片 + 信息块
```

**default**：`MasonryPhotoAlbum` 纯图瀑布流（无信息块），列数按容器宽度回调决定。

**polaroid**：不是普通瀑布流，而是"拍立得相纸撒在桌面上"。三件事必须逐位复刻，否则排布与 Web 完全不同。

**① 6 种相纸规格**（`POLAROID_STYLES`，单位 mm，代码原文）：

| 名称 | cardW | cardH | imgW | imgH | 成像比例 |
|---|---|---|---|---|---|
| 富士MINI | 54 | 86 | 46 | 62 | 0.742 |
| 富士WIDE | 108 | 86 | 99 | 62 | 1.597 |
| 富士SQ | 72 | 86 | 62 | 62 | 1.000 |
| 宝丽来GO | 53.9 | 66.6 | 47 | 46 | 1.022 |
| 宝丽来宽幅 | 103 | 102 | 92 | 73 | 1.260 |
| 宝丽来标准 | 88.5 | 107.5 | 78.9 | 76.8 | 1.027 |

**② 按"图片比例最接近哪种相纸的成像比例"自动选规格**：

```
若 width/height 缺失或非正 → 回退到「宝丽来标准」（数组最后一项）
否则 imgRatio = width / height
    选 argmin |imgRatio − (imgW/imgH)|
```

**③ 确定性错落位置**（无需存储，任何设备算出同一结果）：

```js
// FNV-1a 32 位（iOS 必须用同样的实现，含 Math.imul 的 32 位截断语义）
function hashToUnit(id, salt) {
  let h = (2166136261 ^ salt) >>> 0
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i)
    h = Math.imul(h, 16777619) >>> 0
  }
  return (h % 100000) / 100000
}
// 位置（百分比）
top  = Math.floor(hashToUnit(id, 1) * 40) + 10   // 10% – 50%
left = Math.floor(hashToUnit(id, 2) * 50) + 10   // 10% – 60%
```

> 移植到 Swift 时注意：`Math.imul` 是 32 位有符号乘法（结果按无符号 32 位取），
> Swift 里对应 `UInt32(truncatingIfNeeded:)` 与 `&*`，**不能**用 `Int` 直接乘，否则溢出行为不同、位置会全变。
> 另外 `charCodeAt` 取的是 **UTF-16 码元**，Swift 用 `Array(id.utf16)`。

**④ 其它行为**：卡片宽度 `cardWidth = cardW * scale`，图片内边距 `paddingSide = (cardWidth − imgWidth) / 2`；`width/height` 缺失时该卡片**跳过渲染**（返回 `null`）而不是显示占位。

### 5.2 相册页

复用首页的三种风格（由 `Albums.theme` 决定），数据源为 `album_value`（形如 `/daily`）。分页与排序注意 `Albums.image_sorting` 与 `random_show` 字段。

### 5.3 标签页

`/tag/[...tag]`，使用 default/masonry 风格（`TagGallery`）。标签来源是 `Images.labels`（JSON 数组），生产环境用 `labels::jsonb @>` 做包含查询。

### 5.4 预览页（功能最密集，重点）

布局（桌面为两栏，iOS 需重新组织为纵向）：

```
① 图片区
   - type == 1：ProgressiveImage
       · 底图 = preview_url（800px），0.6s opacity 淡入
       · 上层 = 原图 url，绝对定位覆盖（object-contain，maxHeight 90vh）
       · 支持全屏缩放查看
   - type != 1：LivePhoto（url + video_url）
② 操作区
   - 下载原图（受配置 custom_index_download_enable 控制）
   - 查看原图（受 custom_index_origin_enable 控制）
③ 基本信息（SectionTitle「基本信息」）
   - 标题、描述、时间（formatExifDateTimeForDisplay）
   - 尺寸（dimensions）、像素（megapixels）
④ EXIF 明细：**代码里实际读取的字段只有这些**（`preview-image.tsx` 实测），
   iOS 的 `EXIF` 结构体照此定义即可，不要试图解析全部 EXIF：
   `exif.make` `exif.model` `exif.lens_model` `exif.focal_length` `exif.f_number`
   `exif.exposure_time` `exif.exposure_program` `exif.iso_speed_rating`
   `exif.data_time` `exif.bits` `exif.cfa_pattern`
   时间经 `lib/utils/exif-time.ts` 的 `formatExifDateTimeForDisplay` 归一化（EXIF 的
   `YYYY:MM:DD HH:MM:SS` 格式需转换），iOS 端要复刻同一个归一化规则而不是直接 `DateFormatter` 硬解。
⑤ 影调分析（ToneAnalysis）
   - 结论：low-key / high-key / normal / high-contrast
   - 实现：canvas 取样后自算；iOS 用 CoreImage 直方图统计
⑥ 直方图（HistogramChart）
   - 4 通道叠加：红 / 绿 / 蓝 / 亮度，各 256 bin
   - 亮度通道先画（alpha 0.3）作为背景，再叠加 RGB
   - 每根柱自身顶部渐隐到底部（这是视觉特征，改单区域渐变会让矮柱消失）
⑦ 标签 chips（可点击跳到标签页）
```

### 5.5 地图页

- 数据：`fetchMapImages()` —— 取有 `lon`/`lat` 的图片
- 控件：Marker、Popup、Navigation、Scale、Geolocate、Fullscreen
- **性能注意**：Web 端踩过坑 —— maplibre 的 `move` 事件每帧触发，早期实现直接 `setBounds + setZoom` 导致平移时卡顿。iOS 侧若用 MapKit 不存在该问题，若用 MapLibre Native 需注意同样陷阱。

### 5.6 登录 / 注册

- better-auth，cookie 前缀 `pic-impact`；支持账号密码、Passkey、两步验证
- **注册仅在系统无用户时可用**（`checkUserExists()`，已存在则 `redirect('/login')`）—— iOS 端需复刻这个"首个用户"逻辑
- Passkey 在 iOS 上可用 `AuthenticationServices` 原生实现（比 Web 端更好）
- **若 iOS 端只做浏览，登录可不做**（见 §7 阶段划分）

---

## 6. 视觉规格（像素级）

### 6.1 颜色

见 §1.7 表格。建议在 `DesignSystem/Color+Tokens.swift` 里以语义名命名，**不要**在视图里散写 hex：

```swift
extension Color {
    static let piAccent      = Color(hex: 0x19C8B9)   // 主强调
    static let piPaper       = Color(hex: 0xF0ECE2)   // 纸张
    static let piPaperCard   = Color(red: 247/255, green: 243/255, blue: 223/255)
    static let piPageBG      = Color(hex: 0xF8F8F0)
    static let piBorder      = Color(hex: 0xC4B89E)
    static let piShadowHard  = Color(hex: 0xBDAEA0)
    static let piTextLabel   = Color(hex: 0x9F927D)
    static let piTextValue   = Color(hex: 0x725D42)
    static let piTextStrong  = Color(hex: 0x794F27)
}
```

### 6.2 岛屿卡的双层阴影

```
.shadow(color: .piShadowHard, radius: 0, x: 0, y: 3)       // 硬阴影 = "厚度"
.shadow(color: Color(red:121/255, green:79/255, blue:39/255).opacity(0.08),
        radius: 16, x: 0, y: 4)                             // 柔阴影
```

SwiftUI 的 `.shadow` 可链式叠加，但注意**硬阴影 radius 必须为 0** 才能得到 Web 那种实心偏移效果。

### 6.3 动效

| 项 | 参数 |
|---|---|
| 预览交叉淡入 | opacity，0.6s |
| 卡片阴影/位移过渡 | 0.25s ease |
| 进度条 | 高 3px，`#19c8b9` |
| 直方图动画 | 弹簧，频率 8、阻尼 7，收敛约 0.25–0.5s（Web 端为性能收到 250ms） |

---

## 7. 分阶段计划

| 阶段 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| **P0** | 在 Web 端落地 §2.2 的公开只读接口，冻结 DTO 契约 | 接口 + 契约测试 fixture | **必须先做** |
| **P1** | iOS 骨架：Package 分层、APIClient、Models、DesignSystem tokens | 能跑通 `/api/public/config` + `/gallery` | P0 |
| **P2** | 首页 simple 风格（岛屿卡 + 行优先瀑布流）+ 无限滚动 —— **这是最难也最像的一屏，先做** | 首页 1:1 | P1 |
| **P3** | 预览页全功能（EXIF / 影调 / 直方图 / 下载 / Live Photo） | 预览 1:1 | P2 |
| **P4** | default 与 polaroid 两种风格 + 相册页 + 标签页 | 三种风格齐 | P3 |
| **P5** | 地图页（MapKit） | 地图 1:1 | P2 |
| **P6** | 登录 / 注册 / Passkey | 鉴权 | P5 |
| **P7（可选）** | 上传（PHPicker + 预签名 URL 直传 R2） | 能发图 | P6 |
| **P8（可选）** | 后台管理 | — | P7 |

**建议先做 P0–P3 并冻结**：一口气做全部（含后台）会拖很久，而这四步已经覆盖了浏览体验的全部。

---

## 8. 验收标准

1. **视觉**：同一张图、同一屏尺寸下，与 Web 端截图叠图比对，岛屿卡边框/圆角/阴影偏移、间距、字号误差在 ±2pt 内
2. **顺序**：首页瀑布流的视觉阅读顺序与 Web 完全一致（连续编号逐项核对），且与 DOM/DTO 顺序一致
3. **数据语义**：`show=0`、`del=0`、`type`、`preview_url || url` 四条规则各有单测
4. **契约**：同一份 JSON fixture 在 Web 与 iOS 两端解析通过
5. **性能**：首页首屏 24 张 800px 缩略图，滚动帧率稳定 60fps；图片内存峰值 < 128 MB
6. **离线**：已浏览过的图片在断网时可再现（磁盘缓存生效）
7. **文案**：365 个 key 在四种语言下无缺失（可用脚本比对 JSON 与 `.xcstrings`）

---

## 9. 待你决定的事项

1. **§2.2 方案 A 是否采纳？** 需要我在 Web 端把四个公开只读接口实现出来（含 DTO 契约与测试）。这是 iOS 开工的硬前提。
2. **范围**：只做浏览（P0–P6），还是要包含上传/后台（P7–P8）？
3. **字体保真**：打包子集化的 Noto Sans SC（完全一致，但增大 App 体积），还是回退苹方（体积小，字形有差异）？
4. **地图底图**：用 MapKit（原生、免费、体验好但底图与 Web 的 maplibre 不同），还是 MapLibre Native + 同款底图（视觉一致但要自备 tile 源）？
5. **⌘K 命令菜单**：接受用别的交互替代（并标注非 1:1），还是干脆不做？

---

## 附：本文档的事实来源

| 结论 | 来源 |
|---|---|
| 路由清单 | `find app -name page.tsx` |
| 主题映射 | `app/(theme)/[...album]/page.tsx:90`、`app/(default)/page.tsx:50` |
| 数据模型 | `prisma/schema.prisma` 第 14–84 行 |
| 鉴权边界 | `proxy.ts:8`、`proxy.ts:29-35` |
| 公开接口 | `hono/open/images.ts`、`hono/open/download.ts` |
| 需鉴权接口 | `hono/{albums,images,file,settings}.ts`、`hono/storage/open-list.ts` |
| 设计令牌 | 主题组件与 `style/globals.css` 的用色统计 |
| 岛屿卡几何 | `components/gallery/simple/gallery-image.tsx` 内联样式 |
| 字体 | `style/globals.css:9-14,170` |
| i18n 规模 | `messages/*.json` 统计（365 key） |
| 缩略图规格 | `server/lib/thumbnail.ts` |
| 瀑布流规则 | `components/ui/origin/masonry-grid.tsx` |
| WebGL 查看器 | `components/album/webgl-viewer/` |
| 地图 | `components/layout/theme/map/map-view.tsx`、`package.json` |
