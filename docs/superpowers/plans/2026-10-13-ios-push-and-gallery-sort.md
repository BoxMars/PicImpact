# iOS 推送通知 + 主页「按上传时间排序」实施计划

- **日期**：2026-10-13
- **状态**：待实施（方案已过评审）
- **规格**：推送部分见 `docs/superpowers/specs/2026-10-13-ios-push-notification-design.md`（下称「规格」）；
  排序部分是本文档 §2 的裁决（新增需求，规格里没有）
- **为什么合成一个计划**：**两个功能必须同一次发版**。推送要求用户更新 App 才生效（规格 §9.9），
  排序也是纯新增——分两次发版等于让用户更新两次，而它们的动机是同一件事：
  「推送告诉你刚上传了一张 → 打开 App 要能立刻看到它」。

---

## 目标

1. 任何来源（Web 后台上传 / App 上传）有新照片入库时，手机端收到系统通知，点开直达那张照片。
2. iOS 主页增加「按上传时间排序」选项，让**刚上传的老照片**（EXIF 拍摄时间很早）不再被埋在后面。

---

## Global Constraints

- **必须留在 Vercel Node 运行时**（`app/api/[[...route]]/route.ts:28 runtime='nodejs'`）：APNs 只能用 `node:http2`，
  `fetch` 到 APNs **实测打不通**（规格 §2.2、附录 A）。不得改成 edge。
- **零新增依赖**：服务端用 `node:crypto` + `node:http2`；iOS 侧 `Package.swift` 现在是零依赖，保持。
- **不改 `insertImage`**（它在 `$transaction` 里，是 `'use server'` 数据层）：推送挂在两个入口的**写后副作用**处。
- **推送失败不得影响写路径**：任何时候 APNs 挂了，上传与登记都必须照常成功。
- **公开 API 只做加法**：新增可选查询参数允许，删/改名/改类型/改语义必须开 v2（`docs/superpowers/api/public-api-v1.md:35-45`）。
- **不改 `project.pbxproj`**：工程由 `scripts/ios-project.py` 生成，entitlements 也在那里写出（`:469-481`）。
- 沿用既有 iOS 约定：SwiftUI + iOS 17 + Swift 6 严格并发；复用 `DesignSystem/`；**不 push**。
- **视觉 1:1 是硬要求**（`2026-10-04-ios-replica-design.md:15-20`：「功能可以让步，像素不能让让步」）——
  排序入口的做法必须在不交互时**不改变任何像素**，见 §2.4。

## Review Focus

1. **APNs 连接在 serverless 里的生命周期**：`ClientHttp2Session` 会在实例冻结/回收后失效。
   必须监听 `error`/`close`/`goaway` 并**丢弃单例重建**；不重建的症状是「上线后第一条成功、之后全失败」。
2. **sandbox / production 成对**：设备 `environment` → 端点 → `.p8` key 三者必须一致。
   调试包与发布包混用时表现为静默失败或 `BadDeviceToken`（规格 §2.3、§9.2）。
3. **触发点漏接**：将来新增第三个写图片入口而忘了接线 = 静默不推送。**唯一防线是结构性单测**。
4. **排序必须是服务端 SQL**，且分页要有全序兜底键；客户端排序会让翻页重复/漏图（§2.2）。
5. **切换排序后的磁盘缓存**：`FirstPageCache` 的 key 是硬编码 `"first-page"`（`AppEnvironment.swift:45`），
   若不处理，重启后会先铺出**旧排序**的内容（§2.5）。

---

## 第一部分：推送通知

任务划分与规格 §8 的 P0–P4 对应。每条都写验收。

### Task 1：数据模型与 migration

- 新增 `push_device` / `push_delivery` 两张表（字段见规格 §4.1），纯加法，不动既有表。
- `pnpm prisma migrate dev` 生成 migration 并提交；`prisma:deploy` 在 `build:vercel` 链路里已有（`package.json:13`）。
- 验收：本地库 migrate 通过；`push_device.token` 有唯一约束；`push_delivery` 有 `(userId, createdAt)` 索引。

### Task 2：APNs 客户端（`server/lib/apns.ts`）

- `node:http2` + `node:crypto`（ES256，`dsaEncoding: 'ieee-p1363'`）。**不得出现 `fetch(`**。
- JWT 缓存 50 分钟（官方要求 ≥20 且 ≤60，规格 §2.3）；sandbox / production 各一条独立连接、各一套 key。
- 请求头照规格 §4.2；载荷序列化后断言 `byteLength <= 4096`；单次发送 2.5 秒硬超时。
- 错误分类照规格 §4.8（200 / 400 / 403 / 410 / 429 / 5xx / 超时）。
- 验收：单测覆盖 JWT 头与 claims、头字段、4KB 断言、错误分类；
  **并做一次真实发送**——用手工脚本向一台已注册设备发一条，确认体感与日志。
  （此任务阶段 iOS 侧还没接好，设备 token 可用 `xcrun simctl` 或 Push Console 临时取得，规格 §2.6。）

### Task 3：设备注册接口（`hono/push.ts`）

- 三个端点见规格 §4.6；`app.use('*', requireSession)`（`hono/require-session.ts:33-41`）；
  **把新文件加进 `tests/api/require-session.test.ts:117-131` 的文件清单**（结构性断言会强制要求）。
- `userId` 只从会话取；`token` / `environment` / `clientId` 的校验照规格 §4.6。
- 验收：单测覆盖未登录 401、三类字段校验、按 token upsert（含改归属）、`DELETE` 置 `enabled=0`、
  `GET` 不回显完整 token。

### Task 4：触发接线

- `server/lib/new-image-notify.ts` 的 `notifyNewImage(image)`；在两个入口的写后副作用块各调一次
  （`hono/images.ts:26-32`、`hono/admin/index.ts:120-126`，与 `revalidateTag` 并列）。
- 冷却（同用户 120 秒内只推一条）+ 自传排除（`X-Felina-Client-Id`，规格 §4.4、§4.5）。
- **整个函数 try/catch，永不抛**；失败只 `console.warn`，格式见规格 §4.8。
- 验收：单测覆盖冷却跳过（APNs 客户端零调用）、自传排除、`push_enabled=false` 直接返回、
  **APNs 抛异常时登记接口仍 200**；两条结构性测试：
  - `hono/images.ts` 与 `hono/admin/index.ts` 都必须出现 `notifyNewImage`；
  - `server/lib/apns.ts` 不得出现 `fetch(`。

### Task 5：iOS 工程能力

- `scripts/ios-project.py`：生成**两份** entitlements（debug = `development` / release = `production`），
  两个 build configuration 各用各的 `CODE_SIGN_ENTITLEMENTS`（现在是共用一份，`:355/394`）。
- 人工一次：Apple Developer 后台给 App ID `dev.boxz.felina` 勾上 **Push Notifications**，重新生成 profile。
- 验收：`xcodebuild` `BUILD SUCCEEDED`；`codesign -d --entitlements` 能看到 `aps-environment` 且两配置取值不同。

### Task 6：iOS 权限、注册与心跳

- 新增最小 `AppDelegate`（**必须**，SwiftUI 无等价 API，规格 §2.5），只做 token 回调转发。
- 登录成功后申请 `[.alert, .sound]` → `registerForRemoteNotifications()`；
  拒绝时管理页显示「通知已关闭 · 去系统设置」。
- `clientId`（Keychain UUID）、`environment`（`#if DEBUG` → sandbox）、每次启动心跳调 `POST /api/v1/push/devices`；
  登出调 `DELETE`。上传/登记请求带 `X-Felina-Client-Id`。
- 验收：单测覆盖 clientId 稳定性、token 十六进制化、environment 判定、请求体字段、心跳节流；
  模拟器实测 DB 里出现并维持一行健康记录，杀掉重开仍有效。

### Task 7：接收与跳转

- `willPresent` → 不弹横幅 + 触发 `gallery.pollForUpdates()` 与 `adminList.refreshAfterUpload()`（规格 §5.4）。
- `didReceive` → `userInfo["imageId"]` → 冷启动时存 `PendingRoute`，环境就绪后
  `GET /api/public/v1/images/:id`（已存在，`hono/public-api/v1/index.ts:94`）→ 赋给 `RootView.previewTarget`。
- 验收：`xcrun simctl push` 投递规格 §4.2 的载荷 → 弹出通知 → 点击 → 进入对应预览；图不存在时提示不跳。

### Task 8：配置与设置页

- 环境变量：`APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID`（+ 可选 sandbox 专用 key）。
- `configs` 表新增 `push_enabled`（默认 `"false"`）与 `push_cooldown_seconds`（默认 `"120"`），
  走完整链路：`prisma/seed.ts:5-41`、代码默认值 `fetchConfigValue(..., defaultValue)`、
  `hono/settings.ts` 的 GET+PUT、`server/db/operate/configs.ts` 写入、后台设置页、四语言 `messages/*.json`。
- **PUT handler 里要调 `revalidateTag(CONFIGS_TAG, { expire: 0 })`**：`configs` 有 300 秒缓存，
  不失效就是「改完最多 5 分钟才生效」——这个坑本项目踩过一次（`docs/superpowers/plans/2026-10-07-ios-image-admin.md:242-245`）。
- 验收：后台改开关 → 立刻生效（不等 5 分钟）；关掉后上传照常成功且无推送。

---

## 第二部分：主页「按上传时间排序」（2026-10-13 追加）

### 2.1 动机（这是事实，不是感觉）

iOS 主页请求的是 `GET /api/public/v1/images?page=N`（`APIClient.swift:49,118-128`，`album` 为 nil）→
服务端 `album = '/'` 分支（`hono/public-api/v1/index.ts:144`、`server/db/query/images.ts:185-201`），排序是

```
ORDER BY image.sort DESC, <HOME_IMAGE_SORTING_ORDER>
```

而 `HOME_IMAGE_SORTING_ORDER`（`server/db/query/images.ts:17`）= **EXIF 拍摄时间从新到旧**（回退 `created_at`）。

**后果**：推送告诉你「刚刚上传了一张」，但如果那是 2015 年拍的老照片，它在首页会排到**很后面** ——
通知点开是详情页，可用户回到列表就找不到它了。这就是要加这个选项的原因。

**术语对齐**：项目里既有的说法是**「上传时间 / 拍摄时间」**（`messages/zh.json:249-252` 的
`Album.uploadTimeNewToOld` 等四条，且 iOS 的 `Generated/IslandStrings+Generated.swift:42,49` 已经有了）。
本文档统一用「上传时间」= `images.created_at`（入库时间），不用「发布时间」这个第三种说法。

### 2.2 核心裁决：排序必须落在服务端 SQL

列表是 24 条一页 + 无限滚动（`DEFAULT_SIZE`：`server/db/query/images.ts:18`；
触底加载：`HomeView.swift:102-104`）。**客户端排序只能排「已加载的那几页」→ 翻页必然重复/漏图。**

> 这个坑项目已经踩过并留了记录：`server/db/query/images.ts:212-215` 的注释写着随机展示原来在 JS 里洗牌，
> 「只打乱了已经取到的那 24 行 —— 无限滚动翻页时同一张图可能出现两次、另一张永远看不到」，
> 结论是「随机性必须落在 SQL 侧、且对同一相册**稳定**」。
> **本需求是同一个坑的第二次出现，直接照那条结论办。**

### 2.3 契约：`GET /images` 新增可选参数 `sort`

| 取值 | 实际 SQL（前面一律保留 `image.sort DESC,`） | 说明 |
|---|---|---|
| **缺省** | 首页 = `HOME_IMAGE_SORTING_ORDER`；相册 = `albums.image_sorting` / `random_show` | **= 现状，一个字节都不变** |
| `uploaded_desc` | `image.created_at DESC, image.updated_at DESC, image.id DESC` | 上传时间从新到旧 ← **本次要用的** |
| `taken_desc` | 与 `HOME_IMAGE_SORTING_ORDER` **逐字节相同**（实测 183 字符，= `ALBUM_IMAGE_SORTING_ORDER[2]`） | 拍摄时间从新到旧 |
| `uploaded_asc` | `image.created_at ASC, image.updated_at ASC, image.id ASC` | 上传时间从旧到新 |
| `taken_asc` | `ALBUM_IMAGE_SORTING_ORDER[4]` 那条 | 拍摄时间从旧到新 |

规则：

1. **缺省必须等于现状**——否则就是「改语义」，要开 v2（`public-api-v1.md:35-45`）。
   老客户端不发这个参数，URL、顺序、缓存命中**全部不变**。
2. 非法取值 → **回退到缺省，不报错**（与 `parsePage` 的「非法回退 1」同一风格，`hono/public-api/shared.ts:64-67`）。
3. `?tag=` 模式**本来就已是上传时间从新到旧**（`server/db/query/images.ts:423`）；
   该模式传 `sort` 一律**忽略**（与 `camera`/`lens` 只在 album 模式生效同理），文档写明。
4. **优先级**：`image.sort DESC`（人工置顶）> 显式 `sort` 参数 > 相册 `random_show=0` > `albums.image_sorting`。
   即**显式参数覆盖相册的随机/排序配置**——用户在界面上明确选了排序，就该按他选的来。
5. 首期 iOS **只在主页暴露 2 项**；API 一次给 4 个值，是因为这 4 条 SQL 在
   `ALBUM_IMAGE_SORTING_ORDER`（`:11-16`）里已经存在，**照抄不发明新词汇**，以后要加 UI 不必再改契约。

**分页稳定性（必须做对）**：`created_at` 不唯一（批量上传同秒入库），OFFSET 分页 + 非唯一排序键会重复/漏图。
所以 `uploaded_desc` / `uploaded_asc` 末尾**追加 `image.id`** 作为全序兜底。
（顺带记录：既有相册规则 1/3 只有 `created_at, updated_at`，**同样不唯一**，是既有隐患，本批次不动。）

### 2.4 服务端实现点

| 改哪 | 改什么 |
|---|---|
| `hono/public-api/shared.ts` | 新增 `parseSort(raw)`（照 `parsePage` 的风格，非法回退 `undefined`） |
| `hono/public-api/v1/index.ts:119` | 读 `sort`，传给下面两个查询（`tag` 分支忽略它） |
| `server/db/query/images.ts:176` | `fetchClientImagesListByAlbumImpl` 新增 `sort?: string`；在 `:185` 的 `album === '/'` 分支与 `:208-218` 的 orderBy 组装处生效 |
| `server/db/query/images.ts:258` | 外面那层 `unstable_cache` 不用改：**调用参数自动进缓存键**（`:256-257` 注释），不同排序天然各一份缓存 |
| `docs/superpowers/api/public-api-v1.md` | 参数表加一行 + §6 变更日志加 2026-10-13 一行 |

**不用改**：

- `fetchClientImagesPageTotalByAlbum`（`:111`）：总数与排序无关 → 不分裂缓存。
- `serialize.ts` / DTO / `docs/superpowers/api/fixtures/v1-contract.json` / `scripts/api/verify-contract.ts`：
  排序**不进响应体**，响应形状不变（该脚本只校验响应字段，不碰查询参数）。

### 2.5 iOS 实现点

| 改哪 | 改什么 |
|---|---|
| `Models/DataSource.swift:5-13` | `GalleryDataSource.images(...)` 协议**加 `sort: String?`**（协议改了，`APIClient` 与测试替身跟着改——这正是当初抽协议的价值） |
| `Networking/APIClient.swift:89-105` | `sort` 非 nil 时才进 query（**默认档不发参数**，URL 与今天完全一致，边缘缓存与 `unstable_cache` 继续命中） |
| `Features/Home/GalleryStore.swift:62-74` | `init` 增加 `sort`；`sort` 必须是 `var`（**`album`/`tag` 是 `let`**，`:33-34`，排序要能运行时切） |
| 同上 `:147` 与 `:212-218` | 两处 `dataSource.images(...)` 调用都要带上 `sort`（轮询那条漏了就会「切完排序轮询又拉回默认」） |
| 新 `setSort(_:)` | `guard sort != new`；置 `sort`、`knownPageTotal = nil`（`:58`），然后走 `invalidateCacheAndRefresh()`（`:180-183`） |

**磁盘缓存**：`FirstPageCache` 的 key 硬编码为 `"first-page"`（`AppEnvironment.swift:45` → `Caches/PicImpactMetadata/first-page.json`），
**不含查询条件**。首期用**最少机制**处理：切换排序时 `invalidateCacheAndRefresh()` 已经会 `cache.clear()`（`:181`），
清掉后第一次加载写入的就是新排序的第一页 —— 重启读到的与当前排序一致。
> 若以后想要「两种排序来回切都不重拉」，再把 sort 编进 key（`first-page-<sort>`，
> **默认档保留原 key** 以免老用户升级后缓存全部失效）。现在不做。

**偏好持久化**：全仓库**没有 `@AppStorage`**；`UserDefaults` 只在 `Cache/SeedInstaller.swift` 里作为**可注入参数**用过
（`:37 defaults: UserDefaults = .standard`，测试用 suite 隔离，`SeedInstallerTests.swift:48-49`）。
照这个写法加一个「排序偏好」的小类型（注入 `UserDefaults`），**不要**直接用 `@AppStorage`（Kit 里没法单测）。

### 2.6 UI 入口：与「视觉 1:1」的冲突 —— **已定：方案 A（2026-10-13 用户拍板）**

`2026-10-04-ios-replica-design.md:15-20` 的硬要求是「展示效果 1:1 …… **功能可以让步，像素不能让步**」。
**在头部常驻一个排序控件会直接破坏它**，所以这一条当时留给用户定。**结论：选 A**，
即把已有的计数胶囊变成排序菜单，不交互时不改变任何像素；不加箭头图标（方案 A+ 不做）；B/C/D 全部不做。

| 方案 | 不交互时的像素影响 | 可发现性 | 评价 |
|---|---|---|---|
| **A（推荐）把已有的「N 张照片已收集」胶囊变成排序菜单**（`GalleryHeader.swift:107-121` 的 `counterPill`，用 `Menu` 包住） | **零变化**（菜单只在点开时出现；胶囊本来没有任何手势，不冲突） | 中：用户得知道它能点 | 不破坏 1:1，代码最小 |
| A+ 在胶囊里加一个向下的小箭头提示可点 | 极小（多一个图标） | 高 | 需要给 `Chevron.Direction` 加 `case down`——现在**只有 left/right/up**（`IslandControls.swift:289-293`），`HomeView.swift:166` 的「回到顶部」用的是 `.up` |
| B 缎带下方加常驻分段控件 | **明确破坏 1:1** | 高 | 只有你明确说「1:1 让位于功能」才做 |
| C 标题长按弹菜单 | 零 | 低 | **不可行**：`GalleryHeader.swift:64-65` 已经记录「长按在 ScrollView 里会与滚动竞争，三击则完全不干扰滚动」——这是本项目踩过并写下来的结论 |
| D 放进三击后台页 | 零 | 很低 | 排序是浏览行为，藏进后台不合理 |

- 三击后台入口挂在**标题行**（`GalleryHeader.swift:54-70` 的 `ViewThatFits` 容器上），
  与 `counterPill` 是**兄弟视图**，方案 A 不会抢它的手势。
- 菜单项文案**不需要任何新增 i18n key**：直接用已存在的
  `Album.uploadTimeNewToOld`（上传时间从新到旧）与 `Album.shootTimeNewToOld`（拍摄时间从新到旧）——
  `messages/{zh,en,ja,zh-TW}.json:249-250` 四语言齐全，`Generated/IslandStrings+Generated.swift:42,49` 也已有。
- 现有 10 个 `AnimalIconName`（`AnimalIcon.swift:16-27`）**没有排序/箭头类图标**，所以方案 A 不加图标。

**默认档 = 拍摄时间（现状）**，且**默认档不发 `sort` 参数**——保证「没动过设置的用户」请求与今天逐字节相同。

### 2.7 第二部分的验收

- [ ] **同一份数据、两种排序的可复现对照**：传一张 EXIF 拍摄时间是 2015 年的照片 →
      默认排序下它在首页**靠后**；切到「上传时间从新到旧」后它**是第一张**。
- [ ] 两种排序各自连续翻到底：收集到的 id **无重复、无遗漏**（对照最后一页的实际条数）。
- [ ] 切排序 → 立刻重拉；**杀掉 App 重开，呈现的是切换后的排序**（磁盘缓存没被旧排序污染）。
- [ ] 切排序后，60 秒轮询正常（不会因为跨排序比较而误报「有新内容」或漏报）。
- [ ] `sort` 传非法值 → 回退默认，不报错；`?tag=…&sort=…` → 忽略 `sort`，行为与今天一致。
- [ ] 老客户端（不发 `sort`）行为与今天完全一致；`pnpm api:verify-contract` 通过。
- [ ] 不交互时主页**逐像素与今天相同**（方案 A 的前提；用既有截图对比流程抽查一次头部）。

---

## 本批次验收

1. `xcodebuild` `BUILD SUCCEEDED`；`scripts/ios-test.sh` 全过；`pnpm test:api` 全过；`pnpm api:verify-contract` 通过。
2. **端到端（决定性）**：App 在后台/被杀 → **Web 后台上传一张 EXIF 时间很老的照片** →
   手机收到通知 → 点击进入该图 → 返回列表，**它在第一位**（因为默认已切到「上传时间从新到旧」，或在切换后如此）。
3. 负例全过（规格 §7.3 五条 + §2.7 两条）：
   连传 20 张只响 1 条、手机自己传不振、关权限不报错、登出不再收、`.p8` 写错不影响上传。
4. 生产 APNs（TestFlight 包，production 环境）跑通一次真机锁屏通知。
5. `push_enabled=false` 时行为与今天完全一致（零新增副作用）。

## 后续批次（不在本计划内）

- 缩略图通知（Notification Service Extension，需要工程生成脚本支持多 target）
- 后台刷新兜底（`BGAppRefreshTask`）：前置要先核实 `BGTaskSchedulerPermittedIdentifiers`
  在 `GENERATE_INFOPLIST_FILE=YES` 下怎么写（规格附录 A 的未核实项）
- 相册页 / 标签页也暴露同样的排序选择（契约已经支持，只差 UI）
- 给既有相册排序规则 1/3 补全序兜底键（`image.id`）——既有隐患，见 §2.3
- `push_delivery` 的清理任务（>90 天）。量真涨起来之后再给 `deviceId` 补索引 ——
  目前只有 `(userId, createdAt)`，而冷却判据查的是 `deviceId`；几十到几百行时全表扫描可以忽略，
  但那是唯一一处按 `deviceId` 过滤的查询。

---

## 实施记录与验证（2026-10-13）

### 已完成

**服务端（Task 1–4、8、9）**

- `prisma/migrations/20261013230000_add_push_tables/` 已应用到生产库。**注意**：`prisma migrate diff` 的原始输出里
  夹着一句 `DROP INDEX "images_albums_relation_album_value_imageId_idx"` —— 那是**既有 drift**
  （该索引是 `20261003130000_add_gallery_indexes` 用裸 SQL 建的，Prisma schema 表达不了，diff 就想删掉它），
  **没有照抄**，migration 里只保留两张新表。应用后复核：三条画廊性能索引都还在。
- 生产库 `configs` 补了 `push_enabled='false'` 与 `push_cooldown_seconds='120'` 两行（`configs` 35 → 37）。
  seed 的 `createMany({skipDuplicates})` 只对新库生效，**老库必须手动 INSERT 一次**，这一步已做。
- 新增：`server/lib/apns.ts`、`server/lib/push-api.ts`、`server/lib/new-image-notify.ts`、`server/lib/image-sort.ts`、
  `hono/push/{api,index}.ts`；改动：`hono/index.ts`（挂载）、`hono/images.ts` 与 `hono/admin/{api,index}.ts`（触发接线）、
  `hono/require-session.ts`（会话放 context）、`hono/public-api/v1/index.ts` 与 `server/db/query/images.ts`（`sort`）、
  `hono/settings.ts` + `server/db/operate/configs.ts` + `prisma/seed.ts` + 后台设置页 + 四语言文案（开关与冷却）。

**iOS（Task 5、10、11）**

- `scripts/ios-project.py` 现在按配置生成**两份** entitlements（Debug = `development` / Release = `production`），
  `CODE_SIGN_ENTITLEMENTS` 按配置分别指向它们；老的单份 `FelinaGallery.entitlements` 已删除。
- 排序：`GallerySort` + `GallerySortPreference`、`GalleryDataSource.images(..., sort:)`、`APIClient`、`GalleryStore.sort/setSort`、
  `GalleryHeader` 的胶囊菜单（方案 A）、`AppEnvironment` 注入偏好。

### 验证结果

| 验证 | 命令 / 方式 | 结果 |
|---|---|---|
| 服务端单测 | `node --import tsx --test tests/api/*.test.ts` | **86 passed / 0 failed**（新增 apns 17、push-api 11、push-notify 23、image-sort 6） |
| 公开 API 契约 | `npx tsx scripts/api/verify-contract.ts` | ✓ 通过（响应形状未破坏） |
| 推送接口真 HTTP | 本机 `next dev -p 3210` + 临时会话 | 未登录 401；带会话注册 200 并落库；非法 token → `400 invalid_token`；`GET` 回 `pushEnabled` + 设备列表且 token 只回后 8 位 |
| 后台开关真 HTTP | 本机 `next dev -p 3211` + 临时会话 | `PUT /api/v1/settings/update-push-info` 200（体为受影响行数 2）；**紧接着 GET 就拿到新值**（证明 `revalidateTag(CONFIGS_TAG,{expire:0})` 真的立刻生效）；非法值三例全部 400；复位后再 GET 回 `false`/`120` |
| 排序真 HTTP | 同上，`/api/public/v1/images` | `page=1` 与 `sort=taken_desc` **逐条相同**（默认语义没变）；`sort=uploaded_desc` 顺序明显不同（功能真的生效）；`sort=bogus` 回退到默认 |
| 排序 SQL 复验 | 整理 `EXIF_CAPTURE_TIME_SQL` 的引号风格之后又打了一次真库 | 与整理前**逐条相同**（单测只断言结构性属性，证明「SQL 没被改坏」只能靠真查一次） |
| 真 Prisma 装配 | 脚本直连生产库 | `listDevices` / `albumName(/daily → 大福日常)` / `lastSentAt` / `logDelivery` / `disableDevice` 全部跑通，随后清理 |
| 失败隔离 | 脚本让通知路径在真实装配下抛异常 | 返回 `null` 且**不抛到调用方**（上传路径不受影响） |
| iOS 单测 | `cd ios/PicImpactKit && swift test --disable-sandbox` | **313 tests / 51 suites**，11 issues **全部**是既有环境问题 `认证 · Keychain 读写`（OSStatus `-25300`，见下）；新增 4 个推送 suite + 排序 suite 全绿 |
| iOS App target 编译 | `xcodebuild -project ios/FelinaGallery.xcodeproj -scheme FelinaGallery -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED**（需更宽的沙箱权限，见下） |
| iOS 工程 | `python3 scripts/ios-project.py` + `xcodebuild -list` | 4 个 app 源文件都进了 Sources；两份 entitlements 取值正确、两个配置各指一份 |
| **真上传 → 整条推送链路** | 本机 `next dev` + 真会话 + 真上传（`POST /api/v1/images/add`）+ 假 APNs 凭据 | **跑通并落库**：`push_delivery` 出现 `status=failed reason=InvalidKey`，即「上传 → 入库 → 失效缓存 → 通知 → 查设备 → 发 APNs → 失败被吞 → 落日志」全链成立；上传本身照常 200（失败隔离也顺带验证） |
| 文案同步 | `node scripts/ios-strings.mjs --check` / `ios-strings-swift.mjs --check` | 两个都 ✓（371 × 4 语言） |
| 界面结构审计 | `bash scripts/ios-audit-surfaces.sh` | ✓ 通过 |
| 测试数据清理 | 脚本 | 测试设备行、投递日志、临时会话全部删除（`push_device` / `push_delivery` 均为 0） |

### 没验证到的（诚实列出）

1. **真机 / 模拟器的 APNs 端到端没跑**：需要人工先在 Apple Developer 后台给 `dev.boxz.felina` 勾上
   Push Notifications 并生成 `.p8`（一次性下载，Apple 只给一次）。拿到之后再配 4 个环境变量即可用规格 §7.3 的流程验收。
   （服务端这一侧已经验到「真的发了、真的把 APNs 的拒绝记下来了」——见上表的"真上传 → 整条推送链路"。）
2. **`xcrun simctl push` 投递、前台不弹横幅、点通知进预览、冷启动待跳转** 只有单测 + 类型检查覆盖，**运行时没跑过**。
3. **主页头部的逐像素对比没做**（方案 A 的前提）：需要能跑模拟器的环境截图对比。
4. **`?tag=…&sort=…` 忽略 `sort` 这条没有端到端验证**：本站目前的图片**一个标签都没有**
   （`GET /api/public/v1/tags` 返回 `[]`，库里 `labels` 全空），所以没有可用的 tag 做对照。
   代码层面是确定的：`hono/public-api/v1/index.ts` 的 `if (tag)` 分支只调
   `fetchClientImagesListByTag(page, tag)`，`sort` 根本不会传进去。
5. **`X-Felina-Client-Id` 的"自己不振"只有单测**：验证到「头被发出、`UploadCoordinator` 确实透传」，
   没有端到端（那需要两台真实设备）。

### 两条环境/观测上的注意点

- **`swift test` 必须加 `--disable-sandbox`**：本机 DSH 文件沙箱不允许 SwiftPM 自己 spawn `sandbox-exec`
  （`sandbox_apply: Operation not permitted`）。不加就报 "Invalid manifest"，看起来像代码坏了。
  同理 `xcodebuild` 需要**更宽的沙箱权限**（要写 `~/Library/Caches/org.swift.swiftpm`），
  本次是显式申请后用 `danger-full-access` 跑通 `BUILD SUCCEEDED` 的。
- **`npx next dev` 不会把 handler 里的 `console.info`（stdout）写进重定向的日志文件**
  （`console.warn`/`error` → stderr 能进）。排查"推送为什么没发"时**不要以日志文件为准**，
  要看 `push_delivery` 表 —— 那张表就是为此存在的。生产（Vercel）会正常采集 console 输出。

---

## 需求纠正（2026-10-17）：推送不能跟管理员登录绑在一起

### 错在哪

初版把「设备注册」挂在会话后面（`POST /api/v1/push/devices` 走 `requireSession`），权限弹窗也放在
「登录成功进入管理页」时（本文档 §2.6 之前、规格 §5.2 原版）。

结果就是：**只有用管理员账号登录过的手机才收得到通知**。而这个 App 是给**自己、家人、朋友**看的 ——
朋友只是打开 App 看图，永远不登录，就永远收不到「有新照片」。这与需求正好相反。

### 改成了什么

| 层 | 改动 |
|---|---|
| 数据库 | `push_device.userId` / `push_delivery.userId` 改**可空**；外键 `ON DELETE SET NULL`；索引从 `(userId, enabled)` 换成 `(enabled)` + `(clientId)`，投递日志补 `(deviceId, status, createdAt)` |
| 服务端（路由层） | `POST /devices` 与 `DELETE /devices` **公开**（无需会话）；只有 `GET /devices`（诊断）仍要登录。`userId` 不再写入 |
| 服务端（**中间件层**） | ⚠️ 只改路由不够：`proxy.ts:8` 对**所有** `/api/v1/*` 无 cookie 一律 401，请求根本到不了 Hono。已加唯一放行点：路径**精确等于** `/api/v1/push/devices` 且方法**不是 GET**。实测：匿名 POST 200，匿名 GET 仍 401，其它 `/api/v1` 仍 401 |
| 公开写入的三道闸 | ① `token` 必须十六进制 32–200；② 按 token upsert 去重；③ **启用设备上限 2000**（只数 90 天内活过的，老设备心跳不受限）。再加 APNs 回 410/BadDeviceToken 时自动停用 → 伪造 token 第一次推送后就自我淘汰 |
| iOS | 启动（会话恢复完）就申请权限并注册，**不等登录**；`PushRegistrar` 不再注入会话 Cookie；登出**不再**停用设备（登出只影响上传/管理） |

### 顺带修正的语义

- 「自己传的不通知自己」仍然有效：靠 `clientId`（Keychain 里的 UUID），与账号无关。
- 冷却仍是**每台设备**一次。
- `DELETE /devices` 公开的代价：理论上可以用别人的 `clientId` 把其设备停用。`clientId` 是 App 生成的 UUID
  （不可猜），且该接口只做 `enabled=0`（下一次启动的心跳会把它改回 1）—— 风险可接受。

### 验证

- 服务端单测 **87 passed / 0 failed**（新增 3 条：无会话也能注册、上限 429、心跳在满额时放行）。
- `tests/api/require-session.test.ts` 加了注释：`hono/push/api.ts` 是**部分公开**的已知例外，
  公开面由 `push-api.test.ts` 逐端点断言（POST 无会话 200 / GET 无会话 401）。
- iOS：`swift test --disable-sandbox` → **313 tests / 51 suites**，11 个失败仍是既有的 Keychain 环境问题
  （与改动无关）；改后的注册器用例断言「没有会话也照常注册」。
- `xcodebuild ... build` → **BUILD SUCCEEDED**。
- migration 已应用到生产库，复核：外键 `confdeltype = 'n'`（SET NULL）、新索引就位、
  三条画廊性能索引未被误删。
- **端到端实测（决定性）**：起 `next dev`（假 APNs 凭据）→ **不带任何 Cookie** 注册一台
  「妈妈的 iPhone」→ 站长带会话在网页上传一张 → `push_delivery` 出现
  `status=failed reason=InvalidKey userId=null deviceId=<那台匿名设备>`。
  即「家人装了 App 不登录 → 站长上传 → 家人手机收到（推送尝试）」这条链路成立；
  `reason=InvalidKey` 是假私钥导致的预期失败，真 key 配上就是 `sent`。
  验完已清理（图片/设备/日志全部删除，配置复位 false/120，临时会话已吊销）。

---

## 实施时顺带发现的既有问题（记录，不在本批次修）

1. ~~**`scripts/ios-strings.mjs:18` 的输出路径是错的**~~ —— **本批次已修**：改成
   `ios/FelinaGallery/Resources/Localizable.xcstrings`（工程真正编译的那份），并重跑了两个生成器
   （新增 6 条推送文案 key，371 × 4 语言；Swift 回退表同步）。两个 `--check` 现在都过。
   修之前它一直写进不存在的 `ios/PicImpact/Resources/`，`--check` 永远报"不存在"。
2. `HomeView.swift:155` 注释写「每 5 秒」，实际常量 `updatePollInterval` 是 60 秒（`:67`）。
3. 相册排序规则 1/3 的排序键不含唯一列（`server/db/query/images.ts` 的 `ALBUM_IMAGE_SORTING_ORDER`），
   OFFSET 分页在批量同秒入库时理论上可重复/漏图。
4. CI 既不跑 `pnpm test:api` 也不跑 `scripts/ios-test.sh`（`.github/workflows/eslint.yaml:31-32,39`），
   本批次的验证全靠本地脚本。
5. **`next.config.mjs:17-19` 是 `typescript: { ignoreBuildErrors: true }`**，所以 `npx tsc --noEmit`
   在仓库里本来就有 66 个错误（map-view、file-upload、zod 的 `SafeParseReturnType`、SWR hooks…）。
   **类型检查不是这个仓库可用的门禁**，改代码时不能拿它当"我的改动有没有问题"的判据。
6. **`hono/settings.ts` / `hono/images.ts` / `hono/albums.ts` 里的 `revalidateTag(tag)` 是单参调用**
   （Next 16 需要第二个 `{ expire: 0 }` 参数才会立刻生效）→ 现有 S3 / R2 / OpenList / 自定义信息保存后
   最长要等 300 秒才生效。本批次只给推送开关新开了带 `{ expire: 0 }` 的路径，没动既有的。
7. **`ios/FelinaGallery.xcodeproj/project.pbxproj` 被标了 `skip-worktree`**（`git ls-files -v` 显示 `S`）：
   本地重新生成工程后 `git status` 看不到变化。这是有人有意为之（生成的 pbxproj 里带着本机 `DEVELOPMENT_TEAM`），
   但副作用是**改了工程生成脚本之后，pbxproj 的改动不会进版本库** —— 别人 clone 下来必须自己跑一次
   `python3 scripts/ios-project.py` 才有推送能力。这条要记住。
8. **工程生成脚本的 scheme 模板与真实产物名不一致**：模板写 `BuildableName = "{PROJECT_NAME}.app"`
   （`FelinaGallery.app`），而 `PRODUCT_NAME` 是「大福映画」→ 每次跑脚本都会把 Xcode 修正过的 scheme 又改回去。
   本批次跑完脚本后已把 scheme 还原，未改脚本。
9. **`npx tsc --noEmit` 会重写被跟踪的 `tsconfig.tsbuildinfo`**，`next dev` 会重写 `next-env.d.ts`；
   两者都是构建产物，本批次跑完已还原。
10. **`pnpm` 在本机被 corepack 的版本检查挡住**（`packageManager: 9.7.1` vs 本机 pnpm v11.7.0），
   所以 `pnpm test:api` / `pnpm api:verify-contract` 跑不起来，本批次一律直跑底层命令。
11. **Web 上传路径会把经纬度写成字符串 `"undefined"`**：`POST /api/v1/images/add` 把请求体直接交给
   `insertImage`，而那里是 `lat: String(image.lat)` / `lon: String(image.lon)`（`server/db/operate/images.ts:35-36`）；
   请求里不带 `lat`/`lon` 时就落库成字面量 `"undefined"`（本轮端到端验证时实测到，见响应体）。
   App 的登记路径**已经绕开了**这个坑（`hono/admin/api.ts` 显式 `lat: body.lat ?? ''`）。
   影响：地图页与详情页会把 `"undefined"` 当坐标值（大概率被前端过滤掉，未核实）。**本批次没修**（属既有 Web 路径）。
