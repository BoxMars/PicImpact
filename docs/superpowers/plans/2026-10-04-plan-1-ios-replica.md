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
| T3 `IslandCard` | ⬜ 待做 | 令牌已就绪，只差视图 |
| T5 图片缓存 | ⬜ 待做 | 依赖 DTO（已就绪） |
| T4 `APIClient` + Models | ✅ 完成 | **13 个测试通过**，fixture 为**生产真实响应**（非手写样本）。反验：写错 `previewUrl` 的 CodingKey → 报 `previewURL → ""`；`iso_speed_rating` 不走宽松解码 → 报 `nil != "640"` |
| T7 `HomeView` | ⬜ 待做 | 依赖 T3+T4+T6 |
| T8 首页视觉验收 | ⬜ 待做 | |
| T9–T12 预览页 | ⬜ 待做 | |
| T13–T14 交付前 | ⬜ 待做 | |

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
