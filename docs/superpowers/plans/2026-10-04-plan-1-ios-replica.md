# Plan 1：iOS 展示效果 1:1 复刻（骨架 + 首页 ACNH 瀑布流 + 预览页）

- **日期**：2026-10-04
- **设计依据**：`docs/superpowers/specs/2026-10-04-ios-replica-design.md`
- **API 契约**：`docs/superpowers/api/public-api-v1.md`
- **范围**：设计文档的 P1–P3。相册/标签/地图与截图流水线放 Plan 2；登录/上传放 Plan 3（可选）。
- **硬约束**：展示效果 1:1，样式以 `animal-island-ui`（ACNH）为准。**功能可以让步，像素不能让步。**

---

## 阶段 0：Web 侧（**已完成**，作为本计划的前提）

- [x] `hono/public-api/v1/serialize.ts` —— DTO 契约与冻结点
- [x] `hono/public-api/v1/index.ts` —— `/config` `/albums` `/tags` `/filters` `/images` `/images/:id`
- [x] `hono/public-api/{index,shared}.ts` —— 版本登记表、统一响应头、分页解析
- [x] `app/api/[[...route]]/route.ts` —— 挂载到 `/api/public`（不动任何既有接口）
- [x] `scripts/api/verify-contract.ts` + `docs/superpowers/api/fixtures/v1-contract.json`
- [x] `package.json` 加 `api:verify-contract`；`.github/workflows/eslint.yaml` 加校验步骤
- [x] `docs/superpowers/api/public-api-v1.md` —— 契约与版本政策
- [x] 生产/本地实测：6 个端点全部 200，`indexStyle="1"`、`download=true`，既有 `/api/public/*` 无回归
- [x] 反向验证守护脚本：删字段 / 改类型都能拦下（exit 1），恢复后通过

> Web 侧的后续改动**只允许在 v1 里加字段**。破坏性变更按 API 文档 §4 开 v2。

---

## 进度

| 任务 | 状态 | 验证方式与结果 |
|---|---|---|
| T1 工程与包结构 | ✅ 完成 | `swift build` 通过；`ios/PicImpactKit` 为本地 SPM 包，分层目录就位 |
| T2 `AnimalTokens` | ✅ 完成 | **7 个测试通过**：48 条令牌与 `animal-island-ui/dist/index.css` 逐字对照（基准文件由编译产物直接生成，非手写）。反验：把 `animal-text-color` 改成 `#000000` → 立刻失败 |
| T6 `MasonryLayout` | ✅ 完成 | **9 个测试通过**，含**与 Chrome 实际渲染逐项比对 x/y**（基准由真实浏览器导出）。反验：破坏 span 公式 → 报「第 4 项 y 不一致：Swift 144.0，浏览器 160.0」 |
| T3 `IslandCard` | ✅ 完成 | **6 个像素级测试通过**：用 `ImageRenderer` 栅格化后采样像素，并通过可注入参数**逐个隔离视觉成分**（关掉柔阴影只验硬阴影）。反验：硬阴影偏移归零 → 厚度断言失败；描边改黑 → 报 `#000000 a=255` |
| T5 图片缓存 | ✅ 完成 | **6 个测试**：内存→磁盘→网络三级；磁盘按**最后访问时间**LRU（不是写入时间）；URLProtocol 桩验证「6 个并发请求只打 1 次网络」。反验：并发合并与缓存命中断言均能失败 |
| T4 `APIClient` + Models | ✅ 完成 | **13 个测试通过**，fixture 为**生产真实响应**（非手写样本）。反验：写错 `previewUrl` 的 CodingKey → 报 `previewURL → ""`；`iso_speed_rating` 不走宽松解码 → 报 `nil != "640"` |
| T7 `HomeView` + `GalleryStore` | ✅ 完成 | **9 个测试**覆盖分页状态机（并发触底只加载一次、末页后不再请求、刷新重置、失败可重试、追加去重、前 4 张高优先级）；视图按 `MasonryLayout` 的纯函数结果放置，顺序不需靠肉眼判定 |
| T3b 卡片图标（ACNH 素材） | ✅ 完成 | 8 个彩色 SVG 由 `scripts/ios-icons.mjs` 提取；**本包自己解析渲染矢量路径**（见下）；6 个渲染测试（画出不透明像素/多色/含特征色/矢量缩放） |
| T8 首页视觉验收 | 🟡 部分 | 卡片、令牌、图标均已是像素级验证；整屏截图对比属 T13 流水线 |
| 去 Tab | ✅ 完成 | 按用户要求去掉 TabView，只留画廊（`MapGalleryView` 保留在 kit 里且有测试，日后要加回不必重写） |
| T9 渐进式预览图 | ✅ 完成 | 缩略图先淡入、原图后就绪叠加（0.6s）；`PreviewModel` 状态机测试覆盖加载顺序与「只有一张图」的退化路径 |
| T10 EXIF 面板 | ✅ 完成 | **行构建可测**：只展示 Web 端实际读取的字段、缺失字段不产生空行、时间经归一化、尺寸/像素文案与 Web 一致 |
| T11 影调 + 直方图 | ✅ 完成 | **13 个测试**：算法与 Web 的 JS 实现**跨语言逐值对齐**；渲染层像素验证；下载/地图等见下 |
| T12 下载 / Live Photo | ✅ 完成 | 下载成功记录、失败给可读错误（不抛出界面）、无下载器时空操作安全；iOS 需 `NSPhotoLibraryAddUsageDescription`（已写进工程设置） |
| T13 截图回归流水线 | ⬜ 待做 | 需要 Playwright + 模拟器截图，见下方说明 |
| T14 i18n 一致性 | ✅ 完成 | `scripts/ios-strings.mjs` 由 `messages/*.json` 生成 String Catalog（365 key × 4 语言），`--check` 模式在文案改动未重生成时失败；并校验四语言 key 齐平 |
| 附：Xcode 工程 | ✅ 完成 | `scripts/ios-project.py` 生成工程（工程文件可重新生成、可审查）；`xcodebuild -list` 解析本地包成功 |

**环境记录**：`macOS 26.5.2 / Swift 6.3.2 / Xcode 26.5 / iphonesimulator SDK 26.5`，可直接 `swift test`（无需模拟器）。
`Package.swift` 同时声明 iOS 17 与 macOS 14 —— 后者是为了让 `swift test` 在 Mac 上直接跑，迭代快得多；用到 iOS 专有 API 时用 `#if os(iOS)` 隔开。

**交叉验证的做法（值得沿用到后续任务）**：不自己实现一套"看起来对"的算法，而是让 Web 端渲染同一个组件、把真实几何导出成 golden 数据，再让 Swift 实现去对齐它。
这样"两端一致"是可机器判定的，而不是靠肉眼看截图。

---

## 阶段 1：iOS 骨架与设计系统

### T1. 工程与包结构

- **产出**
  - Xcode 工程 `PicImpact.xcodeproj`（iOS 17+，SwiftUI 生命周期）
  - 本地 Swift Package `PicImpactKit/`，含 `Networking/ Models/ Repository/ Cache/ DesignSystem/`
  - App target 依赖该 Package
- **验证**：`xcodebuild -scheme PicImpact -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` 成功；Package 有独立 test target

### T2. `AnimalTokens` —— 令牌是先决条件，必须最先做

- **文件**：`PicImpactKit/Sources/DesignSystem/AnimalTokens.swift`
- **内容**：设计文档 §1.6 的完整映射（24 个颜色 + 圆角/描边/字号/控件高/间距/动效时长）
- **额外产出**：`TokenGalleryView`（仅供开发，不是产品页）—— 把每个色块、每个圆角规格、每种字号字重并排渲染
- **验证**：把 `TokenGalleryView` 与 `animal-island-ui/dist/index.css` 的 `--animal-*` 声明**逐值对照**（48 条），任何一条不符即为失败
- **注意**：主文字是 `#794F27` 深棕而非黑；`--animal-text-color-muted` 与主文字同值

### T3. `IslandCard` —— 视觉签名的载体

- **文件**：`PicImpactKit/Sources/DesignSystem/IslandCard.swift`
- **规格**（设计文档 §2.3）
  - `cornerRadius 18`
  - 背景 `rgb(247,243,223)`
  - 描边 `2px #c4b89e`
  - 阴影**两层**：`.shadow(radius: 0, y: 3)` 用 `#bdaea0`（硬阴影＝贴纸厚度）＋ `.shadow(radius: 16, y: 4)` 用 `rgba(121,79,39,0.08)`
- **验证**：与 Web 截图叠加比对，重点核对**硬阴影的 3px 偏移是实心、无模糊**
- **反例记录**：硬阴影若给了 radius，会变成普通投影，整张卡就"不像 ACNH"了

### T4. `APIClient` + Models（含契约测试）

- **文件**
  - `PicImpactKit/Sources/Networking/APIClient.swift`
  - `PicImpactKit/Sources/Models/{ImageDTO,AlbumDTO,SiteConfigDTO}.swift`
  - `PicImpactKit/Tests/ContractTests/` —— **同一份 fixture 驱动的解码测试**
- **要点**
  - `CodingKeys` 逐字段对齐 API 文档 §3
  - `lon`/`lat` 保持 `String?`（**不要**解成 Double）
  - `exif` 用只含所需字段的结构体，且**必须容忍未知字段**（不要 `init(from:)` 里 fail）
  - `labels` 容忍 `null` → `[]`
  - 日期用 `ISO8601DateFormatter`
- **验证**：把 Web 端 `/config` `/images` 的**真实响应**存为 fixture 入库，测试解码通过；再补一个"多了一个未知字段仍然解码成功"的用例

### T5. 图片缓存（三级）

- **文件**：`PicImpactKit/Sources/Cache/ImageCache.swift`
- **策略**：内存 `NSCache`（64–128 MB）→ 磁盘 LRU（300 MB–1 GB）→ 网络
- **关键行为**：列表一律取 `previewUrl`（800px）；进入预览页后再后台拉 `url` 原图
- **验证**：断网后已浏览过的图仍能显示；`urlCache` 里对同一 URL 不重复请求

---

## 阶段 2：首页 ACNH 瀑布流（**全项目最难的一步**）

### T6. `MasonryLayout`（行优先）

- **文件**：`PicImpactKit/Sources/DesignSystem/MasonryLayout.swift`
- **算法**（设计文档 §4.5）
  ```
  R = 8（行高粒度，与 Web 一致），G = 16（间距）
  H = 列宽 * (height / width) + 信息块高度
  span = ceil(H / R) + ceil(G / R)
  按服务端返回顺序，在行优先扫描顺序里放第一个能容纳 span 的空位
  **游标只向前推进，不复用已扫过的空洞**
  ```
- **必须避免的坑**（Web 端实测踩过，曾把 180px 的块撑到 3448px）
  - **不要**用"填最短列"的经典瀑布流 —— 那会变成列优先观感
  - 计算高度必须**以内容高度为准**，绝不能让卡片被容器拉伸（否则测量包含预留间距 → 正反馈 → 每轮长 16px）
- **验证（可机器判定，不靠看图）**
  1. 构造 12 个高度 180/260/140/300/200/160/240/120/280/190/220/150 的块
  2. 断言：`y` 最小的那一排按 `x` 排序 == `[1,2,3]`
  3. 断言：按 (y, x) 排序的阅读顺序 == `[1…12]`
  4. 断言：每块实测高度 == 设计高度（±1pt）
  5. 断言：无 `ResizeObserver`/布局循环告警
  > Web 端就是用这套断言发现 bug 的：当时顺序断言通过、**高度断言全部失败**（180 → 3448）。

### T7. `HomeView`（列表 + 无限滚动 + 首屏优先级）

- **文件**：`PicImpactKit/Sources/Features/Home/HomeView.swift`
- **要点**
  - 容器：最大宽 1280，左右 padding 12 / 24 / 40（按尺寸类断点），上下 16
  - 列数断点：**<640 → 1 列；640–1024 → 2 列；≥1024 → 3 列**（与 Web 的 `sm`/`lg` 对齐）
  - 首屏前 4 张走最高下载优先级（对应 Web 的 `fetchPriority=high`）
  - 触底加载 `page + 1`，用 `hasMore` 判断，**不要**用 `pageTotal` 硬算
  - `pageSize` 从 `/config` 读取，不硬编码
- **验证**：`/images?page=1` 返回 24 张时，首屏可见的图与 Web 首屏**顺序一致**；滚动到第 2 页无重复无缺失

### T8. 首页视觉验收

- **验证清单**（设计文档 §5.2 中与首页相关的项）
  - [ ] 背景 `#f8f8f0`、卡片 `#f7f3df`、描边 `#c4b89e` 完全相等
  - [ ] 圆角 18、描边宽 2
  - [ ] 硬阴影 `y=3` 且 `radius=0`
  - [ ] 主文字 `#794f27`、次级 `#9f927d`
  - [ ] 字号 12/14/16 与字重 500/700/800/900
  - [ ] 列间距与行间距 16
  - [ ] **阅读顺序与 Web 逐项一致**
  - [ ] 图片宽高比不被裁切

---

## 阶段 3：预览页

### T9. 预览图（缩略图 → 原图交叉淡入）

- **文件**：`PicImpactKit/Sources/Features/Preview/ProgressiveImageView.swift`
- **行为**：底图 `previewUrl` 先显示并淡入（0.6s）；原图 `url` 加载完成后叠加淡入；`type != 1` 走 Live Photo 分支
- **验证**：慢速网络下（Network Link Conditioner）无空白帧；两层的 `object-fit: contain` 语义（不裁切）保持

### T10. EXIF 面板

- **要点**：只读取这些字段（与 Web 一致）
  `make` `model` `lens_model` `focal_length` `f_number` `exposure_time` `exposure_program` `iso_speed_rating` `data_time` `bits` `cfa_pattern`
- **时间归一化**：复刻 `lib/utils/exif-time.ts` 的 `formatExifDateTimeForDisplay` 规则（EXIF 的 `YYYY:MM:DD HH:MM:SS` 需转换），**不要**直接用 `DateFormatter` 硬解
- **验证**：取若干真实 EXIF 值，与 Web 端渲染出的文案逐字一致

### T11. 影调分析 + 直方图（CoreImage）

- **影调分类**：`low-key` / `high-key` / `normal` / `high-contrast`，判据需与 Web 的 `analyzeTone` 对齐（阈值要抄，不要自己发明）
- **直方图视觉**（设计文档 §2.4⑥）
  - 4 通道各 256 bin：红 `rgb(255,105,97)`、绿 `rgb(52,199,89)`、蓝 `rgb(64,156,255)`、亮度 `rgba(255,255,255,0.6)`
  - 亮度**先画**且 alpha 0.3 作背景，再叠加 RGB
  - **每根柱自身顶部渐隐到底部**（这是视觉特征；换成单个区域渐变会让矮柱几乎看不见）
  - 背景 `rgba(28,28,30,0.95)`，网格线 `rgba(255,255,255,0.04)` ×3 条
- **验证**：同一张测试图，iOS 直方图形状与 Web 一致（截图叠图）；影调结论字符串一致

### T12. 下载与 Live Photo

- **下载**：受 `/config` 的 `features.download` 控制；文件名用 DTO 的 `imageName`；保存需 Photo Library 权限
- **Live Photo**：`url` + `videoUrl`
- **验证**：`features.download=false` 时按钮不出现（**这正是我们修过的布尔语义 bug**，务必用真实配置测两种取值）

---

## 阶段 4：交付前

### T13. 视觉回归基线

- 固定设备 `iPhone 16 Pro (393×852 @3x)`、固定测试数据集（含横/竖/方/超宽）
- Web 侧 Playwright 同视口截图；iOS 侧 `XCUIScreen.main.screenshot()`
- 结构相似度 `SSIM ≥ 0.98`；**令牌级颜色必须完全相等**
- 产出差异热力图，人工确认可接受

### T14. 收尾

- [ ] `pnpm api:verify-contract` 在 Web 侧保持绿（CI 已接）
- [ ] 数据语义单测：`show=0` / `del=0` / `type` / `previewUrl || url`
- [ ] 365 个 i18n key 与 `.xcstrings` 的一致性脚本
- [ ] 子集化打包 Nunito + Noto Sans SC（保字形一致）

---

## 不在本计划内（明确排除）

| 项 | 原因 |
|---|---|
| `default` 纯图瀑布流 | 不是 ACNH 视觉语言（设计文档 §2.2） |
| `polaroid` 拍立得 | 同属 ACNH 但属另一种呈现；算法存档在设计文档 §4.6 |
| 相册页 / 标签页 / 地图 | Plan 2 |
| 登录 / 上传 / 后台 | Plan 3（可选） |
| 自定义光标、hover、⌘K | 触屏无对应概念，不影响展示效果 |

---

## 风险与卡点

| 风险 | 应对 |
|---|---|
| 瀑布流顺序或贴合与 Web 不一致 | T6 的四条断言必须全过再往下走；这是全项目最难点 |
| 卡片被容器拉伸导致高度失控 | 见 T6 的坑；写断言固定住 |
| EXIF `exif` 字段形状不确定 | DTO 原样透传 + 客户端容忍未知字段；契约测试覆盖 |
| 布尔配置语义搞反 | 已修并加断言（`'true'` 而非 `'1'`）；T12 要求两种取值都测 |
| 字体子集缺字 | 用一个包含中日文全字符集的样张在 T8 阶段过一遍 |

### 实施中发现并记录的问题

1. **EXIF 字段类型不统一**：生产响应里 `iso_speed_rating` 是**数字**（`640`），而 `bits` / `f_number` 是字符串。
   按 `String?` 直接解会让整页解码失败。已用 `LenientString` 处理：能解成什么就转成什么，
   遇到不认识的类型返回 nil 而不是抛错 —— 与契约里「客户端必须忽略未知字段」是同一套前向兼容思路。
2. **`createdAt` 带毫秒**（`2026-10-03T11:36:14.539Z`）：`JSONDecoder.iso8601` 不接受小数秒，
   必须自定义策略，否则 24 条全部解不开。
3. **Swift 6 严格并发**：`DateFormatter` / `ISO8601DateFormatter` 都不是 `Sendable`，
   作为 `static let` 共享会直接编译失败。已改为按需新建（调用频率是每张图一次，开销可忽略，
   换来彻底无共享状态）。另：两者没有共同的可调用父类型，**不能塞进同一数组遍历**
   （数组会退化成 `[Formatter]`，没有 `date(from:)`）。
4. **`app/probe-masonry`** 是取浏览器基准用的临时探针页，取完即删（不要提交）。

### T3 的验证手法：隔离 + 差分

像素级验证有两个坑，都踩过并解决了：

1. **两层阴影叠加会糊成一片**，只能给出模糊区间。做法是让 `IslandCard` 的每种视觉成分都可注入
   （`hardShadowColor` / `softShadowColor` 等），测硬阴影时把柔阴影设为 `.clear`，反之亦然，
   这样每条断言都能精确判定。
2. **抗锯齿让"阈值断言"要么过松要么过紧**。圆角顶点实测 alpha = 7（不是 0），
   放宽阈值就等于放水。改为**差分断言**：同一位置渲染 `cornerRadius: 0` 的直角卡作对照 ——
   直角处必须是不透明描边色，圆角处必须近乎透明。这才真正证明了"圆角生效"。

另外 swift-testing 的坑：`#expect` 会把表达式里的参数整体捕获并打印。
若把整个像素缓冲传进去，失败时会输出几万行数组，反而看不见失败原因。
**断言一律先把比较结果算成 `Bool` 再交给 `#expect`**，细节放进消息字符串。

### 卡片图标：一次因为"验证方法本身有错"而走弯路的过程

**问题**：用户反馈"卡片中的小图标没有显示出来"。查证后确认不是渲染失败，而是**我根本没实现**——
Web 卡片信息块里有 8 个 ACNH 彩色图标（EXIF 芯片 5 个 + 操作行 3 个），
我最初只放了一个 SF Symbol 的下载箭头。SF Symbols 是单色线性风格，与这套自绘素材完全不是一回事。

**第一版方案（asset catalog）及其致命缺陷**：
把 8 个 SVG 放进 `Assets.xcassets`。但实测 `swift build -v` 里 **actool 出现 0 次** ——
macOS 的 SwiftPM 只把资源目录原样拷贝，不编译成 `Assets.car`。
经 Xcode 构建 iOS 时会跑 actool（产物里确实有 127KB 的 Assets.car，`strings` 也能查到图标名），
但结果是：**本地完全无法验证图标能否渲染**，而图标缺失又是静默的（界面只是少一块，不报错）。

**最终方案**：改为普通 SVG 资源 + **本包自己解析并渲染矢量路径**（`SVGIcon.swift`）。
这些素材只用 `M/L/H/V/C/Z` 命令与 `path/rect/circle/ellipse` 元素，不含 arc 与二次曲线，解析器可控。
好处：两端行为一致、不依赖 actool、**能在 macOS 上直接断言渲染结果**（`ImageRenderer` 栅格化后查特征色）。

**两处必须注意的细节**：
1. `fill-rule="evenodd"` 必须传 `FillStyle(eoFill:)`，否则图标上的镂空会被实心填掉。
2. 缩放对应 CSS 的 `background-size: contain` + 居中（Web 的 `.animal-icon-*` 就是这么定义的）。

**验证方法本身也踩了坑，值得记下来**：
一开始我在 App 截图里用**精确 RGB** 查图标特征色，结论是"没渲染"——**这是错的**。
抗锯齿与色彩空间会让小图标的颜色偏移（例如 `#FAD12B` 在截图里变成 `#EDB82B`）。
改用**色相比对**后差分结果一目了然：

| | 信息块里出现的色相桶 |
|---|---|
| 加图标之前 | 只有 `15° 30° 45° 60° 75° 90° 105°`（纸/描边/文字的暖色） |
| 加图标之后 | 多出 `120° 135° 150° 165° 180° 195° 210° 225° 255° 270° 330° 345°` |

多出的色相与各图标特征色一一对应（330°=camera 粉、255/270°=camera 紫、165/180°=map 青、
120°=variant 绿、135/150°=shopping 绿）。**像素级断言用色相比精确 RGB 更稳健**，后续沿用。


### 卡片顶边出现"两条边框"：两个各自独立的渲染顺序问题

用户反馈"卡片上方有两个边框"。**确实是实现问题，而且是两个叠加的**：

**其一：硬阴影被画了两次（表现为底边阴影过厚）**
`IslandCard` 自带硬阴影（Web 的 `box-shadow: 0 3px 0 0 #bdaea0`），而 `GalleryCell`
外面又套了 `IslandPressStyle` —— 后者作用的对象是"已带阴影的整张卡"。
实测底边阴影色带从 18px 变成 9px，说明确实去掉了一层。
`IslandPressStyle` 已加上使用范围警告，另新增只做位移、不碰阴影的 `IslandCardPressStyle`。

**其二：`.shadow` 加在 `.overlay { strokeBorder }` 之后（表现为顶边多一条线）**
阴影作用的对象变成"含描边的合成视图"，其顶边落在卡片**内部**，于是在描边内侧挤出一条
`#BDAEA0`。单变量对照实验结果一目了然：

| 变体 | 顶部剖面（x=中点，scale=1） |
|---|---|
| 只到描边 | `y30:#C4B89E  y32:内容` |
| **阴影在描边之后** | `y30:#C4B89E  y32:内容  y33:#BDAEA0  y35:内容` |
| **阴影在描边之前（已改为此）** | `y30:#C4B89E  y32:内容` ✅ |

运行中 App 的三倍图实测同样确认：`y=405..410` 由 `#BDAEA0` 变为照片内容。

**验证方法本身又踩了一次坑（同一类错误第三次）**：
第一版回归测试在遇到第一个内容像素时就 `break`，而那条阴影色恰好出现在内容**之后**一行
（y32 内容、y33 阴影、y35 又内容）——于是测试在错误实现下也通过，是**假测试**。
改成扫满一个窗口、全程不允许出现阴影色之后才有效。
另外还误按 3x 算了描边高度（`ImageRenderer` 的 scale 是 1，2pt 描边只有 2px），
导致正确实现被错判为失败。**教训：断言要么覆盖足够窗口，要么先打印实际剖面看清结构再写。**


### 一次静默挂死：SVG 路径解析器在波浪素材上无限空转

**症状**：`swift test` 不再返回。不报错、不崩溃、没有栈溢出，就是永远不结束；
因为测试并行执行，输出交错，**看起来每次挂的位置都不一样**，很难定位。
更糟的是卡住的测试进程会占住 SwiftPM 的 `.build/.lock`，
于是之后**每一个** `swift build/test` 都静默等锁 —— 整体表现就是"什么都很慢"。

**定位过程**（逐步缩小，每步都限时）：
1. 逐套件隔离 → `GalleryHeaderTests` 挂住，ImageCache / Map 套件正常
2. 逐视图隔离 → `WaveDivider` 与含它的 `GalleryHeader` 挂住，缎带与图标正常
3. 只解析不渲染 → 仍在"解析波浪 SVG"这一步挂住

**根因**：`SVGIcon.path(from:)` 的 tokenizer 在遇到**消费不了的字符**时，
`nextNumber()` 返回 nil 但不推进索引，外层 `while index < data.endIndex` 就空转。
两处具体缺陷：
- 分隔符只处理了空格/逗号/`\n`，**漏了 `\t` 与 `\r`**
- 即使解析失败也不推进索引，**没有终止性保证**

**修复**：分隔符改用 `Character.isWhitespace`；外层循环每轮记录起点，
若整轮未前进就强制前进一个字符 —— 于是解析器**可证明终止**，
任何异常输入都只会少画一点，不会挂死。

**顺带修掉的两件事**：
- `SVGAsset` 增加"某一维无约束"守卫：此时 `scale` 会变成无穷大，
  `context.scaleBy(x: .infinity)` 会让 CoreGraphics 卡死。现在选择不画。
- 新增 `scripts/limited.sh`：跑命令前清理无头 Chrome / 残留测试进程 / 无人持有的构建锁，
  并用 perl 的 alarm 做**硬超时**（macOS 没有 GNU timeout）。超时明确报 124 而不是静默返回 0。
  这个脚本本身就是针对"命令静默挂住"这一问题的对策。

**教训**：模拟器/浏览器/测试这类"可能不返回"的命令，一开始就该有硬超时；
挂住的进程还会互相锁死，产生级联的"慢"。**先有超时，再谈效率。**


### 缎带标题在手机上横向溢出：桌面布局假设不能直接搬到触屏

实机截图做几何分析时发现：缎带前面板的包围盒是 `x=164..1205`（屏幕宽 1206），
**顶到右边缘被切掉**，两侧的 critterpedia / camera 图标被挤出画面。

原因：Web 是桌面布局，28pt 的缎带加上左右各 `1.6em` 内边距接近 **410pt**，
而 iPhone 17 只有 **402pt** 宽 —— 差一点点就放不下。缎带的几何全是 `em` 相对单位，
所以整体等比缩小即可，不需要改设计。

修复：`ViewThatFits(in: .horizontal)` 逐级尝试 28 / 24 / 21 / 18 / 16 / 14pt，
取第一个放得下的。桌面与 iPad 仍取 28pt，与 Web 一致。

修复后实机测量：缎带 `x=202..1004`（67..334pt，宽 267pt，两侧都有留白），
左侧图标 35..44pt、右侧图标 346..351pt，都在画面内。

**回归测试**：渲染 393pt 宽的头部，断言左侧图标出现在左三分之一、右侧出现在右三分之一。
已验证**双向有效**：修复前会报"两侧图标被挤出画面"，修复后通过。

**教训**：Web 的尺寸假设（桌面宽度、hover 态）搬到触屏时必须逐个验证，
不能因为"组件实现是 1:1 抄的"就认为结果也对。这次的溢出只有实测几何才看得出来。


### 用户指出的三处调整

**一、时间只保留日期 —— 这是我移植时的 bug，不是新需求**
Web 的 `formatExifDateTimeForDisplay` 注释与实现都写明输出 `"YYYY-MM-DD"`
（实现是 `normalized.slice(0,10)`），而我的 `displayString` 返回了
`yyyy-MM-dd HH:mm:ss`，于是**卡片和详情页都多显示了时分秒**。
已改名为 `displayDate`（名字里带 Date，避免再次误用）并只返回日期。

**二、卡片操作行：三个图标 → 两个带文字的按钮**
原来照搬 Web 卡片（icon-diy 复制链接 / icon-helicopter 分享 / icon-shopping 下载，只有图标）。
按用户要求改为「分享」「下载」两个胶囊按钮，各自 图标 + 文字，
去掉复制链接。下载仍受站点 features 控制。

**三、详情页：去掉三个按钮 + 美化**
移除操作行（复制链接/分享直链/下载原图），分享与下载统一放在画廊卡片上。
美化：主图装进纸色岛屿卡片（与画廊卡片同一套圆角/描边/硬阴影）、
标题下加青色短横强调、影调分析加比例条、直方图嵌一层浅色面板。

**测试度量又一次踩坑（同一类问题第四次）**：判断"diy 图标是否已移除"时我用了
`#FAD12B` 作为标记色 —— 它确实是 icon-diy 的独占色，但 **icon-helicopter 自己含
`#FFD103`**，与 `#FAD12B` 只差 (5,0,40)，抗锯齿混合后产生了两个落在容差内的像素，
导致测试误报。改用 diy 的另一个独占色 `#E68E6D`（与直升机的橙黄相距很远）。
**教训：像素标记色不仅要"独占"，还要保证临近颜色的抗锯齿混合不会落进容差。**


### 三处视觉微调（用户反馈）

1. **卡片「分享/下载」按钮去掉边框**。顺带去掉了底色 —— 卡片信息块本身贴在纸色上，
   同色底不可见，留着只是多余代码。
   实机核对：操作行条带里 `#c4b89e` 只出现在 `x=36-41` 与 `x=1164-1169`，
   正是卡片自己的左右描边，**没有胶囊轮廓**。

2. **详情页标题与卡片内文字左对齐**。原因是卡片内文字位于
   `16(页面) + 16(卡片内边距) = 32pt`，而标题只有 16pt，差一层。
   新增常量 `cardInnerPadding` 并给卡片外的内容（标题/描述/标签）加上同样的缩进。
   新增像素测试：取标题下的青色短横与卡片内分区标题的起始 x 比对。
   **已验证双向有效**：去掉缩进时会报「标题(短横 x=34)与卡片内文字(x=64)没有左对齐 —— 相差 30px」。

3. **详情页设备信息不显示图标**。只留文字；`DeviceItem.icon` 字段保留（它记录 Web 端
   该行用哪个图标，属数据结构的一部分），只是不渲染。
   原来断言"设备图标应出现"的测试改为断言"不应出现"，并同时确认拍摄参数的
   四个胶囊图标不受影响（那是另一处）。

115 测试 / 14 套件通过。


### 直方图去掉边框 —— 以及"测了组件但没测组合"的漏洞

用户要求直方图不要边框。原边框是我在详情页给直方图加的那层 1px 面板描边
（`HistogramView` 自己只画白色半透明网格与彩色柱，没有边框）。

已抽成独立的 `HistogramPanel`（浅色底 + 圆角，无描边），并在详情页使用。

**验证过程里连续踩了两个坑，都值得记下：**

**坑一：只测组件，测不到调用点的边框。**
第一版测试直接栅格化 `HistogramPanel`，我把边框加回**调用点**时它照样通过 ——
"组件没有边框"和"页面上没有边框"是两件事。
改成在 `PreviewContentView` 的真实组合上检查。

**坑二：半透明描边用精确比色抓不到。**
第二版测试查 `#c4b89e`，但原来那层用的是 `cardBorder.opacity(0.5)`，
渲染出来是 **`#DAD0BB`** —— 与 `#c4b89e` 相差很远，测试又是通过。
实测出混合色后，改成**同时查实心与半透明两种**才真正生效。

**定位直方图的方式也返工过**：先用它的深色底找，结果柱体把底色盖住了
（所有箱同值时每根柱都是满高，底色只剩几十个像素），
改用"**最后一个青色分区标题**"作锚点（直方图是最后一节）。

最终这条测试**双向有效**：现状通过；在调用点加回半透明边框时报
「实测在 y=2111...2366 命中 100 px」。

117 测试 / 14 套件通过。


### 分享改走系统面板；详情页 ACNH 顶栏；图片下方圆角

**一、分享调系统分享面板**
卡片的「分享」从"复制到剪贴板"改为 `ShareLink`（系统分享面板），分享站点链接
`https://felina.boxz.dev/preview/<id>`。用 `ShareLink` 而不是自己包
`UIActivityViewController`：iPad 上 popover 的锚点、取消回调都由系统处理，
自己包容易在 iPad 上崩（popover 必须有 sourceView）。
`LinkActions.copyShareLink` 保留作为降级路径。

**二、详情页 ACNH 顶栏（返回 / 分享）**
左上「返回」、右上「分享」，都是纸色胶囊 + 图标 + 文字，并隐藏系统导航栏。
- 返回用 `@Environment(\.dismiss)`：从任意入口（卡片、标签、深链接）进来都能正确返回
- 返回箭头是**自绘**的：这套 ACNH 图标里没有方向箭头，
  而 SF Symbol 的 `chevron.left` 是细线风格，与旁边的 ACNH 图标不是一套
- `.toolbar(.hidden, for: .navigationBar)` 需要 `#if os(iOS)` 守卫 ——
  这个 placement 在 macOS 上不存在，而本包要同时给 macOS 测试编译

**三、图片下方圆角**
`.clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))`，
半径 16 取自 Web 的 `border-radius: 16px 16px 0 0`。

**过程中查出一个更底层的渲染问题（值得记下）**：
加上圆角后发现"裁掉的圆角处透出的不是纸色，而是卡片自己的硬阴影色"。
最小复现确认：

| 卡片内容 | 圆角/透明处透出 |
|---|---|
| `IslandCard { Color.clear }` | 纸色 ✓ |
| `IslandCard { VStack { 带 clipShape 的色块; Color.clear } }` | **硬阴影色** ✗ |

也就是说：**内容里一旦出现 `.clipShape` 的子视图，`IslandCard` 那层 `fill` 就不露出来了**。
（同一现象也解释了图片与信息块交界处那条一直存在的 20px 暗带 —— 它之前一直被图片盖住。）
修法：给图片区显式垫一层 `.background(cardPaper)`，且必须放在 **clipShape 之后**
（放前面会被同一个 clipShape 一起裁掉，等于没加）。

**这条像素测试返工了四次**，每次都因为断言不够稳健：
1. 采样点选在圆弧**内部** → 测不到
2. 断言"必须露出精确纸色 #F7F3DF" → 实际裁边有抗锯齿、颜色是纸色系但非精确值 → 假失败
3. 改成"不是图片色"但容差 5 → 圆角外的 #F0EAD4 与图片色 #F0E8D8 只差 (0,2,-4) → 假失败
4. 容差收到 2 才稳（占位色是纯平色，2 足够）

120 测试 / 14 套件通过。
