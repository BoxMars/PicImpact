# iOS 展示效果 1:1 复刻设计文档（PicImpact / 大福映画 Felina Gallery）

- **日期**：2026-10-04（第 3 版）
- **版本沿革**：v1 全量功能复刻 → v2 按"只要求展示效果 1:1、样式以 ACNH 为准"重写 →
  **v3 收敛范围为「只做 ACNH 岛屿卡一种呈现」，`default` 纯图瀑布流与 `polaroid` 均不做**（见 §2.2）
- **目标**：iOS 原生（SwiftUI）复刻 Web 站点，**展示效果 1:1**
- **视觉权威**：`animal-island-ui` v1.0.16（动物森友会 ACNH 风格组件库）
- **被复刻对象**：`https://felina.boxz.dev`（Next.js 16 + Hono + Prisma + R2）
- **文档性质**：设计规格。所有令牌与几何均逐条取自编译产物或仓库代码，未核实处显式标注。

---

## 0. 目标与范围

### 0.1 硬要求只有一条：展示效果 1:1

**"1:1" 只约束视觉呈现** —— 配色、圆角、描边、阴影、字体、间距、排布顺序、信息层级。
**不约束**实现方式、技术选型、功能取舍。凡是"看起来一样"就算达标；凡是"看起来不一样"就不达标，无论功能多完整。

这条约束把优先级彻底改写了：**功能可以让步，像素不能让步**。

### 0.2 视觉权威是 ACNH

站点的整套视觉来自 `animal-island-ui`（ACNH 风格组件库，`package.json` 依赖 `^1.0.16`）。
它是**唯一权威**，不要凭截图猜颜色 —— 令牌、纸卡配色、立体阴影、六边形光环全都能从它的编译产物里精确取到（见 §1）。

> 实测确认：核心令牌 48 个 `--animal-*` 变量、纸卡 13 种配色、24 个组件导出。
> 以下 §1 全部为**逐条抄录**，非推测。

### 0.3 我已替你做的决定

原文档末尾列了 5 个待决策项。按你说的"别的我自己定"，我直接定掉，不再问：

| 事项 | 决定 | 理由 |
|---|---|---|
| 列表数据接口 | **在 Web 端新增 4 个公开只读接口**（§3.3），我先实现并冻结 DTO | 否则 iOS 拿不到"相册里有哪些图"，是硬前提 |
| 范围 | **只做 ACNH 岛屿卡这一种呈现**（首页 + 相册 + 标签 + 预览 + 地图）；`default` 纯图瀑布流不做；上传/后台放最后且可选 | 见 §2.2 —— `default` 与 ACNH 是两套完全不同的视觉语言，混做会让"展示效果 1:1"失去基准 |
| 字体 | **打包子集化的 Nunito + Noto Sans SC** | 既然样式要 1:1，字形就不能用苹方替代 |
| 地图底图 | **MapKit** | 地图不是"展示效果"的核心；MapKit 零成本且体验更好 |
| ⌘K 命令菜单 | **不做** | 键盘交互，不属于展示效果 |
| 自定义光标 / hover | **不做** | 触屏无此概念（§7） |

---

## 1. ACNH 设计系统（权威令牌）

### 1.1 完整令牌表（48 个，逐条抄自 `animal-island-ui/dist/index.css`）

**颜色**

| 令牌 | 值 | 用途 |
|---|---|---|
| `--animal-bg-color` | `#f8f8f0` | 页面背景（暖白纸） |
| `--animal-bg-color-secondary` | `#f0e8d8` | 次级背景 |
| `--animal-bg-color-disabled` | `#f0ece2` | 禁用背景 |
| `--animal-primary-color` | `#19c8b9` | 主强调（青绿） |
| `--animal-primary-color-hover` | `#3dd4c6` | |
| `--animal-primary-color-active` | `#50b9ab` | |
| `--animal-primary-color-bg` | `#e6f9f6` | 主色浅底 |
| `--animal-success-color` | `#6fba2c` | 成功（草绿） |
| `--animal-success-color-hover` | `#85cc45` | |
| `--animal-success-color-active` | `#5a9e1e` | |
| `--animal-warning-color` | `#f5c31c` | 警告（金黄） |
| `--animal-warning-color-hover` | `#f7d04a` | |
| `--animal-warning-color-active` | `#dba90e` | |
| `--animal-error-color` | `#e05a5a` | 错误（砖红） |
| `--animal-error-color-hover` | `#e87878` | |
| `--animal-error-color-active` | `#c94444` | |
| `--animal-text-color` | `#794f27` | **主文字 = 深棕，不是黑** |
| `--animal-text-color-muted` | `#794f27` | （库中与主文字同值） |
| `--animal-text-color-secondary` | `#9f927d` | 次级文字（label） |
| `--animal-text-color-disabled` | `#c4b89e` | 禁用文字 |
| `--animal-border-color` | `#aaa69d` | 默认描边 |
| `--animal-border-color-light` | `#e8e2d6` | 浅描边 |
| `--animal-border-color-hover` | `#827157` | |
| `--animal-mask-bg` | `rgba(0,0,0,.35)` | 遮罩 |

**几何 / 尺寸**

| 令牌 | 值 |
|---|---|
| `--animal-border-radius-sm` / `base` / `lg` | `16px` / **`18px`** / `24px` |
| `--animal-border-width` | `2px` |
| `--animal-font-size-sm` / `base` / `lg` | `12px` / `14px` / `16px` |
| `--animal-height-sm` / `base` / `lg` | `32px` / `40px` / `48px` |
| `--animal-line-height-base` | `1.5715` |
| `--animal-spacing-xs`/`sm`/`md`/`lg`/`xl` | `4` / `8` / `12` / `16` / `24` px |

**阴影**

| 令牌 | 值 |
|---|---|
| `--animal-shadow-sm` | `0 2px 4px 0 rgba(61,52,40,.06)` |
| `--animal-shadow-base` | `0 3px 10px 0 rgba(61,52,40,.1)` |
| `--animal-shadow-lg` | `0 8px 24px 0 rgba(61,52,40,.14)` |

**动效**

| 令牌 | 值 |
|---|---|
| `--animal-motion-duration-fast`/`base`/`slow` | `.15s` / `.25s` / `.35s` |
| `--animal-motion-ease` | `cubic-bezier(.4,0,.2,1)` |

### 1.2 纸卡 13 色（`CardColor`，逐条抄自 `AI_USAGE.md`）

纸卡是本项目最核心的视觉元素（首页瀑布流每张卡片就是一个 `Card color="default"`）。

| 值 | 背景 | 文字 |
|---|---|---|
| **`default`** | **`rgb(247,243,223)` = `#f7f3df`** | **`#725d42`** ← **生产在用** |
| `app-pink` | `#f8a6b2` | `#fff` |
| `purple` | `#b77dee` | `#fff` |
| `app-blue` | `#889df0` | `#fff` |
| `app-yellow` | `#f7cd67` | `#725d42` |
| `app-orange` | `#e59266` | `#fff` |
| `app-teal` | `#82d5bb` | `#fff` |
| `app-green` | `#8ac68a` | `#fff` |
| `app-red` | `#fc736d` | `#fff` |
| `lime-green` | `#d1da49` | `#3d5a1a` |
| `yellow-green` | `#ecdf52` | `#725d42` |
| `brown` | `#9a835a` | `#fff` |
| `warm-peach-pink` | `#e18c6f` | `#fff` |

另有 `CardPattern`：以这 13 色之一作为**装饰纹理叠加**（`'none'` 或上述任一值）。
卡片还有 `type: 'default' | 'dashed'`。

### 1.3 三个视觉签名（丢掉任何一个，就"不像 ACNH"了）

**① 立体按钮阴影 —— "厚度"**

```css
box-shadow: 0 3px 0 0 var(--animal-*-color-active);   /* 按下前的实体厚度 */
box-shadow: 0 6px 0 0 …;  /* 更大的规格 */
box-shadow: inset 0 2px 4px #725d4226;                /* 按下后的内凹 */
```

关键在 **radius 必须为 0**：那是一个实心偏移，不是模糊。iOS 用 `.shadow(radius: 0, y: 3)` 还原。

**② 六边形光环**（用于选中/强调态）

```css
box-shadow:
  0 -18px 0 -8px #19c8b9,  16px -8px 0 -8px #19c8b9, 16px 8px 0 -8px #19c8b9,
  0  18px 0 -8px #19c8b9, -16px  8px 0 -8px #19c8b9, -16px -8px 0 -8px #19c8b9;
```

六个实心圆角块围成一圈 —— ACNH 那种"花朵/叶子状光环"。iOS 可用 6 个偏移 shadow 叠加还原。

**③ `2px solid #c4b89e` 描边 + 纸色填充**

这是全库出现最多的组合（`#c4b89e` 在编译 CSS 中出现 64 次，为最高频颜色）。
本项目岛屿卡在此基础上又叠了一层硬阴影 `0 3px 0 0 #bdaea0`（见 §2.3）。

### 1.4 组件清单（24 个导出，供对照实现）

```
Button  Input  Switch  Modal  Card  Title  Collapse  Cursor  Time  Phone
Footer  Divider  Typewriter  Tabs  Icon  Select  Checkbox  Radio  Tooltip
Loading  Table  CodeBlock  WeddingInvitation  WeddingInvitationExportButton
+ ICON_LIST（图标目录，10 项）
```

**本项目真正用到的**（其余仅作参考）：`Card`、`Button`、`Tooltip`（已在本轮替换为原生 `title`）、`Icon`、`Loading`、`Modal`、`Tabs`、`Title`、`Divider`。

与本项目 iOS 端直接相关的变体：

| 组件 | 变体 |
|---|---|
| `Button` | `type: primary \| default \| dashed \| text \| link`；`size: small \| middle \| large` |
| `Card` | `type: default \| dashed`；`color`: 见 §1.2；`pattern`: 见 §1.2 |
| `Title` | `size: small \| middle \| large`；`color:` 多值 |
| `Input` | `size: small \| middle \| large` |
| `Switch` | `size: small \| default` |
| `Checkbox`/`Radio` | `size: small \| middle \| large` |
| `Tooltip` | `placement`、`trigger: hover \| focus \| click`、`variant: default \| island` |
| `Footer` | `type: sea \| tree`（ACNH 主题化） |
| `Divider` | 多 type |

### 1.5 字体

```css
font-family: Nunito, "Noto Sans SC", -apple-system, "PingFang SC",
             "Hiragino Sans GB", "Microsoft YaHei", sans-serif !important;
```

- 实际用到的字重：**400 / 500 / 600 / 700 / 800 / 900**
- 注意编译产物里还有一个自定义字体 `animal-dialog`（`font-family: animal-dialog, Nunito-SemiBold, sans-serif`），用于对话框标题
- 字体由库通过 `@fontsource` 自带；本项目因性能考虑改成了 `unicode-range` 分片（见 §2.6）

### 1.6 iOS 令牌映射（建议直接照此建 `DesignSystem`）

```swift
// DesignSystem/AnimalTokens.swift
enum Animal {
    // 颜色
    static let bg            = Color(hex: 0xF8F8F0)
    static let bgSecondary   = Color(hex: 0xF0E8D8)
    static let bgDisabled    = Color(hex: 0xF0ECE2)
    static let primary       = Color(hex: 0x19C8B9)
    static let primaryHover  = Color(hex: 0x3DD4C6)
    static let primaryActive = Color(hex: 0x50B9AB)
    static let primaryBg     = Color(hex: 0xE6F9F6)
    static let success       = Color(hex: 0x6FBA2C)
    static let warning       = Color(hex: 0xF5C31C)
    static let error         = Color(hex: 0xE05A5A)
    static let text          = Color(hex: 0x794F27)   // 深棕，非黑
    static let textSecondary = Color(hex: 0x9F927D)
    static let textDisabled  = Color(hex: 0xC4B89E)
    static let border        = Color(hex: 0xAAA69D)
    static let borderLight   = Color(hex: 0xE8E2D6)
    // 纸卡
    static let cardPaper     = Color(hex: 0xF7F3DF)   // CardColor.default 背景
    static let cardText      = Color(hex: 0x725D42)

    // 几何
    static let radiusSM: CGFloat = 16
    static let radius: CGFloat   = 18
    static let radiusLG: CGFloat = 24
    static let borderWidth: CGFloat = 2
    static let fontSM: CGFloat = 12
    static let fontSize: CGFloat = 14
    static let fontLG: CGFloat = 16
    static let heightSM: CGFloat = 32
    static let height: CGFloat   = 40
    static let heightLG: CGFloat = 48
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 24
}
```

**不要**在视图里散写 hex —— 令牌集中的意义就是日后 ACNH 换色时只改一处。

---

## 2. 被复刻对象：页面与视觉结构

### 2.1 路由

| URL | 说明 |
|---|---|
| `/` | 首页画廊（风格由全局配置决定） |
| `/[...album]` | 相册页（`album_value` 形如 `/daily`）——iOS 统一 ACNH 风格，忽略其 `theme` 字段 |
| `/tag/[...tag]` | 按标签浏览 —— iOS 统一 ACNH 风格 |
| `/preview/[...id]` | 图片预览详情 |
| `/map` | 地图页 |
| `/login`、`/sign-up` | 鉴权（iOS 首期可不做） |
| `/admin/*` | 后台（iOS 首期不做） |

### 2.2 iOS 只做 ACNH 一种呈现（决定）

Web 端其实有**两套正交的主题开关**，取值映射一致
（`app/(default)/page.tsx:65-69`、`app/(theme)/[...album]/page.tsx:90`）：

| 取值 | Web 主题组件 | 视觉语言 |
|---|---|---|
| `'1'` | `simple-gallery` | **ACNH 岛屿纸卡** + 行优先瀑布流 + 卡片下方信息块 |
| `'2'` | `polaroid-gallery` | 同属 ACNH 视觉语言的拍立得变体（相纸撒桌面） |
| 其他/`'0'` | `default-gallery` | `MasonryPhotoAlbum` **纯图瀑布流，无信息块 —— 不是 ACNH 语言** |

**决定：iOS 端只实现 `'1'` 这套 ACNH 岛屿卡。**

由此推出三条必须落实的规则：

1. **`default` 不做。** 它是纯图瀑布流（无纸卡、无描边、无立体阴影），与 ACNH 是两套视觉语言。既已确定样式以 ACNH 为准，它就没有复刻基准。
2. **忽略 `Albums.theme` 字段。** 生产实测：首页 `custom_index_style = 1`（ACNH），而相册 `/daily` 的 `theme = 0`（default）。
   若 iOS 遵循该字段，打开 `/daily` 就会渲染我们不打算实现的风格。**因此 iOS 端所有列表（首页 / 相册 / 标签）统一使用 ACNH 岛屿卡呈现**，
   `theme` 字段在客户端一律忽略（仅作为服务端数据存在，见 §3.1）。
3. **`polaroid` 首期不做。** 它同属 ACNH 视觉语言、共用 §1 的全部令牌，属于"另一种呈现"而非另一种风格；
   按"只做 ACNH 一种"收敛范围，首期排除。因其算法已完整记录在 §4.6，日后要加成本很低（只需多一个布局器，令牌与卡片复用）。

> 这条决定的实际影响：**iOS 端只有一套画廊视图 + 一个布局算法**，不需要按相册切换渲染分支。
> 它同时消掉了原文档里"同一站点两种风格并存，两套都得做"的复杂度。

### 2.3 simple 风格的岛屿卡（像素级）

取自 `components/gallery/simple/gallery-image.tsx` 的实际内联样式：

```
border-radius   18
background      rgb(247, 243, 223)        // = #f7f3df = CardColor.default
border          2px solid #c4b89e
box-shadow      0 3px 0 0 #bdaea0,        // 硬阴影 = 贴纸厚度（radius 0！）
                0 4px 16px rgba(121,79,39,0.08)   // 柔阴影
transition      box-shadow .25s ease, transform .25s ease
contain         layout style
```

`#bdaea0` 是纸卡自己的"厚度色"，比描边色 `#c4b89e` 略深，叠出立体感。

**容器与网格**：

```
容器   maxWidth 1280，居中；左右 padding 12 / 24 / 40（sm / md 断点）；上下 16
网格   1 列（<640）/ 2 列（640–1024）/ 3 列（≥1024）；列间距 16，行间距 16
```

### 2.4 预览页（信息最密集的一屏）

```
① 图片区
   · type == 1：底图 preview_url（800px，0.6s opacity 淡入）→ 上层原图 url 覆盖
   · type != 1：LivePhoto（url + video_url）
② 操作：下载原图（受 custom_index_download_enable 控制）、查看原图（受 custom_index_origin_enable）
③ 基本信息：标题、描述、时间、尺寸、像素
④ EXIF：代码实际读取的字段只有这些（照此定义 struct 即可，别解析全部 EXIF）
      make / model / lens_model / focal_length / f_number / exposure_time
      / exposure_program / iso_speed_rating / data_time / bits / cfa_pattern
   时间经 lib/utils/exif-time.ts 的 formatExifDateTimeForDisplay 归一化
   （EXIF 的 `YYYY:MM:DD HH:MM:SS` 需转换），iOS 要复刻同一套规则
⑤ 影调分析：low-key / high-key / normal / high-contrast
⑥ 直方图：4 通道（红/绿/蓝/亮度）各 256 bin；亮度先画（alpha 0.3）作背景再叠 RGB；
   **每根柱自身顶部渐隐到底部** —— 这是视觉特征，换成单个区域渐变会让矮柱几乎看不见
⑦ 标签 chips（可跳到标签页）
```

### 2.5 地图页

数据取有 `lon`/`lat` 的图片。Web 用 `maplibre-gl` + `react-map-gl`。iOS 用 MapKit（§0.3）。
**Web 踩过的坑**：maplibre 的 `move` 每帧触发，早期直接 `setBounds + setZoom` 导致拖动卡顿 —— iOS 用 MapKit 无此问题。

### 2.6 字体在 Web 端的处理（iOS 端要借鉴其取舍）

Web 端为性能把字体换成了 `unicode-range` 分片的 `@fontsource` 版本：

```css
font-family: Nunito, 'Noto Sans SC', -apple-system, 'PingFang SC', sans-serif;  /* globals.css:170 */
@import "@fontsource/nunito/{500,700,900}.css";
@import "@fontsource/noto-sans-sc/{400,500,700}.css";
```

原因：原库内联了**未分片**的 Noto Sans SC（单字重约 1.1 MB），实测仅其中几个分片命中就约 550 KB。
**iOS 端对应做法**：把同一套字体**子集化**（只保留实际用到的字符集 + 三种字重）打包进 App，既保字形一致又控体积。

---

## 3. 数据与接口

### 3.1 数据模型（iOS 端只需理解 4 张表）

```
Images    id, image_name, url(原图), preview_url(800px), video_url, blurhash,
          exif(Json), labels(Json), width, height, lon, lat, title, detail,
          type(1=图片, 非1=LivePhoto), show(0=公开), show_on_mainpage(0=上首页),
          sort, createdAt, updatedAt, del(0=未删)
Albums    id, name, album_value(@unique), detail, theme('0'|'1'|'2' ← iOS 忽略，见 §2.2),
          show, sort, random_show, image_sorting, license
ImagesAlbumsRelation   (imageId, album_value) 复合主键，多对多
Configs   config_key(@unique), config_value, detail
```

**⚠️ 语义坑（务必写测试固定）**：`show = 0` 才是公开、`del = 0` 才是未删除 —— 与直觉相反。

### 3.2 接口现状与阻断项

`proxy.ts:8` 让 `/api/v1/*` 全部需要会话 cookie：

```ts
if (request.nextUrl.pathname.startsWith('/api/v1') && !sessionCookie) {
  return Response.json({ success: false, message: 'authentication failed' }, { status: 401 })
}
```

而**相册列表、图片列表、标签列表全是服务端渲染时直接查库得到的，没有 HTTP 接口**。
公开的只有三个：`/api/public/images/get-image-by-id`（单张）、`/api/public/images/get-image-blob`（字节代理）、`/api/public/download/:id`。

**结论：iOS 目前无法获取"某相册有哪些图"。必须先补接口。**

### 3.3 我要新增的公开只读接口（决定采纳，先做）

在 Web 端新增，复用现有查询与 `unstable_cache` 缓存，不触碰现有鉴权边界：

```http
GET /api/public/config
→ { custom_title, custom_author, custom_logo_url, custom_index_style,
    custom_index_download_enable, custom_index_origin_enable }

GET /api/public/albums
→ AlbumDTO[]                    // 仅 show=0 且 del=0

GET /api/public/gallery?album=%2Fdaily&page=1&size=24
→ { list: ImageDTO[], total, page, hasMore }

GET /api/public/tags
→ string[]
```

`ImageDTO` **只暴露客户端需要的字段**（不回传 Prisma 实体）：`id, url, preview_url, video_url, blurhash, width, height, title, detail, type, labels, lon, lat, exif, createdAt`。
`lon`/`lat` 在库里是 **String**，DTO 保持 `String?` 避免解码失败。

---

## 4. iOS 工程

### 4.1 选型

| 项 | 选择 | 理由 |
|---|---|---|
| UI | SwiftUI | 声明式布局 + `Layout` 协议契合瀑布流 |
| 最低版本 | iOS 17 | 需要 `Layout` 协议、`MagnifyGesture`、`@Observable` |
| 并发 | Swift Concurrency | |
| 网络 | `URLSession` + `Codable`，手写轻量 client | 只有 4 个接口 |
| 图片 | `AsyncImage` 起步，需要磁盘缓存/预取时换 Kingfisher | 画廊重度用图 |
| 状态 | `@Observable`（Observation） | |

### 4.2 分层

```
PicImpactKit/                  Swift Package，与 App 分离便于测试
  Networking/   APIClient、Endpoint、错误映射
  Models/       ImageDTO / AlbumDTO / SiteConfig（与 §3.3 契约一一对应）
  Repository/   GalleryRepository、AlbumRepository、ConfigRepository
  Cache/        ImageCache（内存 NSCache + 磁盘 LRU）
App/
  Features/     Home / Album / Tag / Preview / Map
  DesignSystem/ AnimalTokens、IslandCard、MasonryLayout、AnimalButton
```

**`Models/` 必须配契约测试**：同一份 JSON fixture 在 Web 与 iOS 两侧都跑，否则后端改字段会静默崩。

### 4.3 导航映射

| Web | iOS |
|---|---|
| `/` | `HomeView`（Tab 1） |
| `/[...album]` | `AlbumView(albumValue:)` push |
| `/tag/[...tag]` | `TagView(tag:)` push |
| `/preview/[...id]` | `PreviewView(id:)` push |
| `/map` | `MapView`（Tab 2） |

Web 端还有 `app/@modal/(...)preview/[id]` —— 预览能以模态覆盖列表。iOS 可同时支持 push 与 sheet。

### 4.4 图片加载

1. **内存** `NSCache`（上限 64–128 MB）
2. **磁盘** LRU 300 MB–1 GB
3. **网络**：**先 `preview_url`（800px）渲染，再后台拉 `url` 原图** —— 这是 Web 的行为（交叉淡入），也是体感关键

资产域返回 `Cache-Control: immutable` 且 URL 是内容哈希命名 → **磁盘缓存可永不失效**，无需处理换图（换图必换 URL）。

### 4.5 瀑布流：必须行优先（iOS 侧核心算法）

Web 端此前用 CSS 多列，是**列优先**的（先填满第 1 列再填第 2 列），导致按时间排序的照片变成"一列读到底" —— 已改为行优先 Grid。iOS 必须复刻**行优先**，所以：

**不要**用"填最短列"的经典瀑布流（那会改变顺序为列优先观感）。正确规则：

```
行高粒度 R = 8，间距 G = 16（与 Web 一致，保证空隙观感相同）
对每个 item 按服务端返回顺序依次：
  H = 列宽 * (item.height / item.width) + 信息块高度
  span = ceil(H / R) + ceil(G / R)
  在行优先扫描顺序里找第一个能容纳 span 行且空闲的位置
  游标只向前推进，不复用已扫过的空洞   ← 这是与 Web 一致的关键
```

信息块高度（标题/日期/EXIF/标签/操作）**必须计入 H**；Web 是用 `ResizeObserver` 实测的。
iOS 建议先用固定高度 + 标题最多两行截断，把不可控因素收敛。

> 相关坑（Web 端实测踩过）：网格项若允许拉伸（`align-items: stretch`），测量到的高度会把"为间距多留的行"算进去，下一轮 span 再变大 → **正反馈，每轮长 16px 直至失控**（实测把 180px 的块撑到 3448px）。iOS 计算时必须**以内容高度为准，不允许被容器拉伸**。

### 4.6 拍立得主题的算法（**首期不做，仅存档**）

> 按 §2.2 的决定，`polaroid` 不在首期范围。本节保留完整算法记录，原因是：它的排布完全由
> 哈希决定，**不逐位复刻就会与 Web 完全不同**；日后若要做，照此实现即可，令牌与卡片可直接复用。

**① 6 种相纸规格**（`POLAROID_STYLES`，单位 mm，抄自代码）：

| 名称 | cardW | cardH | imgW | imgH | 成像比 |
|---|---|---|---|---|---|
| 富士MINI | 54 | 86 | 46 | 62 | 0.742 |
| 富士WIDE | 108 | 86 | 99 | 62 | 1.597 |
| 富士SQ | 72 | 86 | 62 | 62 | 1.000 |
| 宝丽来GO | 53.9 | 66.6 | 47 | 46 | 1.022 |
| 宝丽来宽幅 | 103 | 102 | 92 | 73 | 1.260 |
| 宝丽来标准 | 88.5 | 107.5 | 78.9 | 76.8 | 1.027 |

**② 按"图片比例最接近哪种相纸成像比例"自动选规格**：

```
width/height 缺失或非正 → 回退「宝丽来标准」（数组最后一项）
否则 imgRatio = width / height，取 argmin |imgRatio − (imgW/imgH)|
```

**③ 确定性错落位置**（无需存储，任何设备算出同一结果）：

```js
// FNV-1a 32 位
function hashToUnit(id, salt) {
  let h = (2166136261 ^ salt) >>> 0
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i)
    h = Math.imul(h, 16777619) >>> 0
  }
  return (h % 100000) / 100000
}
top  = Math.floor(hashToUnit(id, 1) * 40) + 10   // 10%–50%
left = Math.floor(hashToUnit(id, 2) * 50) + 10   // 10%–60%
```

> **移植陷阱**：`Math.imul` 是 32 位有符号乘法（无符号 32 位截断），Swift 要用 `&*` + `UInt32`，用 `Int` 直接乘溢出行为不同、位置会全变；
> `charCodeAt` 取 **UTF-16 码元**，Swift 用 `Array(id.utf16)`。

**④ 其他**：`cardWidth = cardW * scale`，图片内边距 `paddingSide = (cardWidth − imgWidth) / 2`；宽高缺失时该卡片**跳过渲染**（`null`）而非占位。

---

## 5. 视觉保真的验收方法

既然唯一硬要求是"展示效果 1:1"，验收就必须是**可测量的**，不能靠"看着像"。

### 5.1 截图对比流程

```
1. 固定设备与系统：iPhone 16 Pro（393×852 pt @3x）
2. 固定数据：指向一份固定的测试数据集（含横图/竖图/方图/不同比例），避免每次内容变化
3. Web 侧：用 Playwright 以同样视口、同样 devicePixelRatio 截图同一批页面
4. iOS 侧：XCTest 的 `XCUIScreen.main.screenshot()`
5. 逐像素比对（建议阈值：结构相似度 SSIM ≥ 0.98；令牌级颜色必须**完全相等**）
6. 输出差异热力图，人工确认差异是否可接受
```

### 5.2 逐项检查清单（必须全部通过）

- [ ] 页面背景 `#f8f8f0`、卡片纸色 `#f7f3df`、描边 `#c4b89e` 三者**完全相同**
- [ ] 卡片圆角 18、描边宽 2
- [ ] 卡片的**硬阴影偏移 = 3px 且无模糊**，柔阴影 `0 4px 16px rgba(121,79,39,.08)`
- [ ] 主文字色 `#794f27`（**不是黑**）、次级 `#9f927d`
- [ ] 主强调色 `#19c8b9`
- [ ] 字号 12/14/16 与字重（500/700/800/900）与 Web 一致
- [ ] 瀑布流列数断点 640 / 1024，列间距与行间距 16
- [ ] **瀑布流的视觉阅读顺序与 Web 完全一致**（连续编号逐项核对）
- [ ] 图片宽高比**永不被裁切**
- [ ] ~~拍立得排布位置~~（首期不做，见 §2.2；若日后加入则需逐张核对 §4.6 的哈希移植）
- [ ] 各页面文案与 Web 一致（365 个 key，四种语言）
- [ ] 动效时长符合令牌（.15 / .25 / .35s）

### 5.3 数据语义单测（视觉之外的必测项）

`show=0`、`del=0`、`type`、`preview_url || url` 四条规则各一个单测。

---

## 6. 分阶段计划

| 阶段 | 内容 | 完成标志 |
|---|---|---|
| **P0** | Web 端落地 §3.3 的 4 个公开只读接口 + 冻结 DTO + 契约 fixture | 接口可用，fixture 入库 |
| **P1** | iOS 骨架：Package 分层、APIClient、Models、`AnimalTokens`、`IslandCard` | 能拉到 config/gallery 并渲染出**一张正确的岛屿卡** |
| **P2** | 首页 simple 风格：岛屿卡 + **行优先瀑布流** + 无限滚动 | §5.2 相关项全过（这屏最难，先做） |
| **P3** | 预览页：交叉淡入、EXIF、影调、直方图、下载、Live Photo | 预览页视觉 1:1 |
| **P4** | 相册页 + 标签页（**统一 ACNH 风格**，忽略 `Albums.theme`，见 §2.2） | `/daily` 等相册页与首页视觉一致 |
| **P5** | 地图页（MapKit） | |
| **P6** | 截图对比流水线（§5.1）接入 CI | 每次提交自动出差异报告 |
| **P7（可选）** | 登录 / 上传（PHPicker → 预签名直传 R2） | |
| **P8（可选）** | 后台管理 | |

**建议 P0–P3 先冻结交付**：这四步已覆盖用户看到的一切，且 P2 的瀑布流是全项目最难的部分。

---

## 7. 不做 / 无法 1:1 的清单（明确排除，避免后期扯皮）

| 项 | 原因 | 处理 |
|---|---|---|
| **`default` 纯图瀑布流** | 不是 ACNH 视觉语言（无纸卡/描边/立体阴影），无复刻基准 | **不做**，见 §2.2 |
| **`polaroid` 拍立得** | 同属 ACNH 语言但属"另一种呈现"，按"只做 ACNH 一种"收敛 | 首期不做；算法存于 §4.6，日后成本很低 |
| 自定义光标 `island-cursor` | 触屏无 hover 概念 | 不做 |
| hover 态 | 同上 | 改 `pressed` / 长按反馈 |
| ⌘K 命令菜单 | 键盘交互 | 不做 |
| 顶部 3px 浏览器进度条 | 浏览器导航语义 | 不做（或换成等价反馈） |
| title 原生提示 → iOS | 无等价物 | 长按提示 |
| 键盘快捷键、右键菜单 | 桌面语义 | 不做 |

> 这些都不影响"展示效果 1:1" —— 它们要么不是视觉，要么在触屏上根本不存在。

---

## 附：本文档的事实来源

| 结论 | 来源 |
|---|---|
| 48 个令牌 | `animal-island-ui/dist/index.css` 的 `--animal-*` 声明，逐条抄录 |
| 纸卡 13 色 | `animal-island-ui/AI_USAGE.md` §1.5 `CardColor` |
| 组件与变体 | `AI_USAGE.md` §1 全文（1041 行，24 个导出） |
| 视觉签名（3D 阴影/六边形光环/2px 描边） | 编译 CSS 的 `box-shadow` / `border` 取值统计 |
| 字体栈与字重 | 编译 CSS 的 `font-family` / `font-weight` 统计 |
| 岛屿卡几何 | `components/gallery/simple/gallery-image.tsx` 内联样式 |
| 路由清单 | `find app -name page.tsx` |
| 两套主题映射 | `app/(default)/page.tsx:65-69`、`app/(theme)/[...album]/page.tsx:90` |
| 数据模型 | `prisma/schema.prisma` 第 14–84 行 |
| 鉴权边界 | `proxy.ts:8`、`proxy.ts:29-35` |
| 公开接口 | `hono/open/images.ts`、`hono/open/download.ts` |
| EXIF 字段 | `components/album/preview-image.tsx` 中实际读取的 `exif.*` |
| 拍立得规格与哈希（首期不做，存档） | `components/layout/theme/polaroid/polaroid-gallery.tsx`（`POLAROID_STYLES`、`hashToUnit`） |
| 瀑布流规则与正反馈坑 | `components/ui/origin/masonry-grid.tsx` 及其修复记录 |
| 缩略图规格 | `server/lib/thumbnail.ts`（最长边 800、webp q76） |
| 字体分片处理 | `style/globals.css:5-14,170` |
