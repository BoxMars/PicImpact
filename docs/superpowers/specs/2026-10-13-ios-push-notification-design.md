# iOS「新照片上传」推送通知 技术方案（PicImpact / 大福映画）

- **日期**：2026-10-13（第 1 版）
- **目标**：任何来源（Web 后台上传 / App 上传）有新照片入库时，**手机端收到系统通知**，点开直达那张照片
- **被改造的两端**：Hono API（Vercel Node 运行时）+ iOS App（SwiftUI，bundle `dev.boxz.felina`）
- **文档性质**：设计规格。所有现状结论都带 `文件:行号` 出处；所有平台约束都来自 Apple 官方文档或**本机实测**（§2、附录 A）；
  凡未核实的都显式标注「未核实」，不写成结论。

---

## 0. 结论与决定

### 0.1 一句话方案

**在「新图片入库」这唯一收敛点上，服务端用 `node:http2` 直连 APNs 发一条 alert 推送（token-based 认证，ES256 JWT）；
App 端加 `aps-environment` 能力、一个最小 AppDelegate 拿 device token、并把 token 注册到新表 `push_device`。**

不引入任何第三方推送服务、不引入任何依赖、不加 cron、不引入队列。

### 0.2 我已替你做的决定

参照 `2026-10-04-ios-replica-design.md` §0.3 的做法，能定的我直接定掉：

| 事项 | 决定 | 理由 |
|---|---|---|
| 推送通道 | **自建 APNs 直推**（不走 OneSignal/Expo/极光） | 用户只有一个、发送频率极低；第三方要多一个账号、多一份数据出境、多一个 SDK 依赖。而 iOS 侧 `Package.swift` **零第三方依赖**是既有硬约束（`ios/PicImpactKit/Package.swift` 全文 29 行无 `dependencies`） |
| APNs 协议实现 | **`node:http2` 手写**，不用 `fetch`、不装 `undici`/`apn` 库 | `fetch` 到 APNs **实测失败**（附录 A）；项目依赖里没有 undici（`node_modules` 只有 `undici-types`）。手写量约 120 行，且行为可测 |
| 兜底通道 | **首期不做**，只保留现有 60 秒前台轮询 | 静默推送 / `BGAppRefreshTask` 都不可靠（§2.8），做它们不能替代主通道，只增加复杂度 |
| 通知样式 | **纯文本**（标题 + 相册 + 图片标题），**不做缩略图** | 带图需要新增 Notification Service Extension target，而工程由脚本单 target 生成（`scripts/ios-project.py`），成本明显高于收益。列为 P4 |
| 前台行为 | **不弹横幅**，把推送当作「立刻刷新列表」的信号 | 前台时用户正看着画廊，横幅是噪音；画廊会自动刷新，效果等价 |
| 自己传的不通知 | **排除「发起这次上传的那台设备」** | 上传完 App 自己就会刷新，再响一声是打扰。用客户端自带的稳定 `clientId` 排除 |
| 防刷屏 | **同用户 N 秒内只推一条**（默认 120 秒，可配） | 20 张图 = 20 次登记调用，不合并就是 20 条推送 |
| 凭据存放 | **`.p8` / Key ID / Team ID 放环境变量**；**开关与冷却秒数放 `configs` 表** | 秘密与凭据归部署期注入；行为开关归运行期可改。这与 R2 凭据放表里（`server/lib/preview-storage.ts:26-33`）**有意不同**，理由见 §4.7 |
| 权限申请时机 | **启动时**（会话恢复完就申请）—— **2026-10-17 纠正** | ❌ 初版写的是「登录成功、进入管理页时」，那是**设计错误**：推送要发给**所有装了 App 的人**（家人/朋友），跟「谁是管理员」无关。登录只用于上传/管理 |
| 遗留版本 | **明确接受**：老版本 App 收不到通知，必须更新到带推送的新版本 | 无解。App Store 发版节奏决定（§9.9） |

### 0.3 需要你拍板的 4 件事

| # | 问题 | 我的建议 | 影响 |
|---|---|---|---|
| 1 | 触发范围：只有**别人/网页**上传才通知，还是**所有**上传都通知？ | 除「正在上传的那台设备」外全部通知（即：网页上传 → 手机响；手机自己传 → 手机不响；另一台设备传 → 都响） | 一行判断 + 一个请求头（§4.5） |
| 2 | 前台收到推送要不要也弹横幅？ | 不弹，只刷新 | 一行代码（`willPresent` 的返回值） |
| 3 | 通知里要不要带照片缩略图？ | 首期不做（P4） | 要新增一个 Xcode target，工程生成脚本要支持多 target |
| 4 | `.p8` 放环境变量还是放数据库 `configs`？ | 环境变量 | 放表里会进 `db-backups/` 的 dump，且设置页要处理「只写不回显」 |

**这 4 条都不阻塞开工**，P0/P1 与它们无关。

---

## 1. 现状（事实）

### 1.1 事件源：新图片入库的唯一收敛点

**唯一权威收敛点**是 `server/db/operate/images.ts:16` 的 `insertImage(image)`（真写库在 `:21 tx.images.create`，被 `db.$transaction` 包住 `:20-65`；同事务写关系表 `:57`）。

它的调用点**全仓库只有 2 个**，对应两个 HTTP 入口：

| 入口 | 路由 | handler | 调 `insertImage` |
|---|---|---|---|
| Web 后台上传 | `POST /api/v1/images/add` | `hono/images.ts:34` | `hono/images.ts:56` |
| App 上传登记 | `POST /api/v1/admin/images` | `hono/admin/api.ts:166` | `hono/admin/index.ts:89` |

补充事实：

- 两个入口都先调 `attachManagedImageMetadata`（`hono/images.ts:54`、`hono/admin/index.ts:87`；实现 `server/lib/managed-image.ts:26`），但它只做预览图/宽高/blurhash/EXIF，**不含任何通知**。
- 入库后**唯一的既有副作用**是缓存失效：`hono/images.ts:57 invalidateImages()`（`revalidateTag(IMAGES_TAG)`）与 `hono/admin/api.ts:204 invalidate()`（`revalidateTag(IMAGES_TAG,{expire:0})`）。
- 新图 `show` / `show_on_mainpage` 被写死为 `0`（`server/db/operate/images.ts:46-47`），即**登记进来的一定是公开图**——这消掉了一个隐私问题（§6）。
- **没有第三个入口**：没有 cron、没有导入脚本直插（`scripts/migrate/backfill-exif-capture-time.ts:97` 只 update）。

### 1.2 iOS 端现在怎么「知道有新照片」

| 机制 | 位置 | 说明 |
|---|---|---|
| 前台轮询 | `HomeView.swift:67`（`updatePollInterval = .seconds(60)`）、`:157-163` | 60 秒一次，**只在页面存在期间运行** |
| 轮询判据 | `GalleryStore.swift:144-158` | `pageTotal` + 第一页 id 序列变化才真刷新（`:152`） |
| 回前台立即查 | `HomeView.swift:150-154` | `scenePhase == .active` 时 `pollForUpdates()` |
| 首屏缓存 | `Cache/FirstPageCache.swift:15-49`、`GalleryStore.swift:107-118` | 「先出缓存，再后台校验」 |
| 上传后刷新 | `GalleryStore.swift:180-183` | 作废磁盘缓存 + 重拉 |

**关键缺口**：**后台没有任何刷新或唤醒路径**。代码只在注释里假定「切后台 iOS 会挂起进程，轮询自然暂停」（`HomeView.swift:155-156`）。
也就是说：**App 不在前台时，用户永远不知道有新照片**——这正是本方案要补的那一块。

### 1.3 已有的与没有的

| 项 | 现状 | 出处 |
|---|---|---|
| 推送能力 | **完全没有**。entitlements 只有 `com.apple.developer.associated-domains` | `ios/FelinaGallery/FelinaGallery.entitlements:5-8` |
| `aps-environment` / `UIBackgroundModes` / `BGTaskSchedulerPermittedIdentifiers` / `SystemCapabilities` | 全仓库 **0 命中** | pbxproj 全文 + grep |
| 通知相关代码 | `UNUserNotificationCenter` / `registerForRemoteNotifications` / `BGAppRefresh` 等 **0 命中** | grep |
| App 入口 | `@main struct PicImpactApp: App`，**无 AppDelegate**、无 `UIApplicationDelegateAdaptor` | `PicImpactApp.swift:6-25` |
| 设备标识 | **没有**。`identifierForVendor` 0 命中；Keychain 里只有会话 Cookie | `AuthStore.swift:26`、`KeychainStore.swift:48` |
| 会话 | 手工管理的 better-auth Cookie，存 Keychain；用户名/id 不落盘 | `AuthStore.swift:74-78,177-197` |
| 服务端事件钩子 | **没有** `after()` / `waitUntil` / 队列 / cron（grep 0 命中）；`vercel.json` 只有 `regions:["sin1"]` | `vercel.json:1-6` |
| 设备表 | 没有；`User`（`prisma/schema.prisma:85-101`）也没有设备字段 | schema |
| 推送依赖 | 服务端依赖里无任何推送 SDK；iOS `Package.swift` 无任何依赖 | `package.json`、`Package.swift` |
| 用户模型 | **事实上的单管理员独占站**（注册页有用户即 redirect，无 role，图片无归属） | `app/sign-up/page.tsx:16-20`、schema |

### 1.4 部署形态（决定了「能不能说 HTTP/2」）

生产 = **Vercel（函数区域 `sin1`）+ Supabase Postgres（`ap-southeast-1`）**，Cloudflare 只做前置代理 + R2 图床
（`README.md:42,45,46`、`next.config.mjs:21-24`、`vercel.json:3-5`）。

**Cloudflare 迁移是 no-go**：`docs/superpowers/plans/2026-10-07-cloudflare-migration.md:3-5` 原文「状态：❌ 不推进（2026-10-07 决定）」、`:17`「**因此：留在 Vercel + Supabase。**」；
仓库内无 `wrangler.toml` / `open-next.config.ts` / wrangler 依赖。
（该文件 `:441` 有一句「后续不再使用 Vercel 与 Supabase」与之矛盾，属文档内部矛盾段，被顶部状态否定——本方案**按留守 Vercel 设计**。）

Hono 挂载在 `app/api/[[...route]]/route.ts`，`:27 dynamic='force-dynamic'`、`:28 runtime='nodejs'`——**Node 运行时是本方案的硬前提**。

---

## 2. 平台硬约束（官方文档 + 本机实测）

这一节是本方案最贵的部分：下面每一条都决定了一个设计选择。

### 2.1 APNs 必须 HTTP/2 —— 而且 HTTP/1.1 是连接层就死

Apple：「Use HTTP/2 and TLS 1.2 or later to establish a connection」；
「APNs doesn't support legacy binary protocol as of March 31, 2021」
（[Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)）。

**本机实测**（附录 A）：对 `api.push.apple.com` 用 HTTP/1.1 POST 得到的是 **`code=000`（根本没有 HTTP 响应）**，
用 HTTP/2 才拿到 `403 {"reason":"MissingProviderToken"}`。
这条不是「最好用 HTTP/2」，是「**HTTP/1.1 根本连不上**」。

### 2.2 服务端运行时能不能说 HTTP/2 —— `fetch` 不能，`node:http2` 能

**本机实测**（Node v25.8.1，附录 A）：

```
plain-fetch  → TypeError: fetch failed            ← Node 内建 fetch(undici) 默认 HTTP/1.1，打不通 APNs
node:http2   → status=403 {"reason":"MissingProviderToken"}   ← 通了
```

结论与推论：

- **绝对不能用 `fetch` 发 APNs 推送**。这是最容易被「顺手写成 fetch」坑掉的地方。
- Node 内建 `http2` 可用。项目依赖里**没有** undici（只有 `undici-types`），若要用 undici 的 `allowH2` 就得新增依赖，而它本身在多处被报告在 Node 22+ 上会 `fetch failed`；**不值得**。
- 结论：**手写 `node:http2` 客户端**。这同时满足「不新增依赖」的既有约束。

### 2.3 token-based 认证的规则（照抄，别自己发明）

来源：[Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)（全文已核）。

- JWT 四项：`alg` **只支持 ES256**；`kid` = 10 字符 Key ID；`iss` = 10 字符 Team ID（本项目 `VX3SCAKB5K`）；`iat` = epoch 秒。
- `iat` 超过 1 小时 → `403 ExpiredProviderToken`。
- **刷新节奏是双向约束**：「Refresh your token **no more than once every 20 minutes** and **no less than once every 60 minutes**」；同一条连接上 20 分钟内换新 token 也会报错。
  → 实现上取 **50 分钟**缓存（同时满足两边）。
- **Key 是分环境的**：新 key「restrict usage to either Sandbox or Production」；只能同时支持两环境的老 key「will continue to be supported」。
  → 服务端要按设备的 `environment` 选 **key + 端点**，两者必须配对（§4.2）。
- **一条 HTTP/2 连接在第一次推送时就被绑定到 team + bundle**：「APNs relates a team ID and associated bundle IDs to a connection on the first push…attempting to associate a different team or sending a push to a newly added bundle ID causes an error.」
  → **sandbox 与 production 必须各用一条独立连接**，不能混（否则第二次推送报错，而且很难查）。
- 端点：生产 `https://api.push.apple.com:443`、沙箱 `https://api.sandbox.push.apple.com:443`（另有 2197 端口备用）。

### 2.4 载荷与投递语义

同一份文档（已核）：

- 载荷 **上限 4 KB**（VoIP 5 KB），**不得压缩**。
- 必需头：`:method POST`、`:path /3/device/<device_token>`、`apns-topic`（= **bundle id**，即 `dev.boxz.felina`）、`authorization: bearer <JWT>`。
- `apns-push-type`：alert 用 `alert`；后台更新用 `background`（**必须 priority 5，用 10 是错误**）。
- `apns-priority`：立即送达 `10`；`5` 省电。
- `apns-expiration`：非 0 = APNs 会存并重试到该时刻（最长 30 天）；`0` = 只投一次不存。
- `apns-collapse-id`：同值合并成一条（≤64 字节）。
- `apns-id`：建议自己生成 UUID 并记录，便于排障（APNs 会在响应里回它）。
- HPACK 提示：`:path` 与 `authorization` 要按「literal without indexing」编码——**这条对 Node 的 `http2` 是透明的**（NDV/敏感头由 Node 处理），不需要自己实现 HPACK。
- APNs 是 best-effort：`priority 5/1` 的推送「might get grouped and delivered in bursts…may also get throttled, saved in storage, and in some cases, not delivered」。

### 2.5 拿 device token 必须有一个 AppDelegate

SwiftUI 没有「注册远程通知并拿到 token」的等价 API：
`UIApplication.shared.registerForRemoteNotifications()` 的结果只会回到 `UIApplicationDelegate` 的
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` / `…didFailToRegister…`。

→ **必须引入一个最小的 `UIApplicationDelegateAdaptor`**。这与 `PicImpactApp.swift:6` 的注释「用 SwiftUI 生命周期（无 AppDelegate）」冲突，属于**必须打破的既有约定**，要在文档与提交信息里写明理由。

### 2.6 三种可用的验证手段（决定了 §7 怎么写）

| 手段 | 说明 | 出处 |
|---|---|---|
| `xcrun simctl push <udid> <bundleid> payload.json` | 模拟器直接投递一条推送，**不需要服务端、不需要 token**。用来验证渲染 / 点击 / 跳转 | 本机 Xcode 自带 |
| Xcode 14+ 的模拟器**能向 APNs 注册并拿到真实 sandbox token** | 「Starting Xcode 14, iOS Simulator is able to communicate with APNs in order to register for notification in the sandbox environme…」；**但**在 Mac 虚拟机里拿不到 token | [Apple 论坛](https://developer.apple.com/forums/thread/796868) |
| Apple **Push Notification Console** | 苹果官方的推送测试控制台，**不写服务端就能发测试推送**，还能看投递日志 | [Testing notifications using the Push Notification Console](https://developer.apple.com/documentation/usernotifications/testing-notifications-using-the-push-notification-console) |

→ 这意味着 **「服务端 APNs 客户端」与「iOS 端渲染/跳转」可以并行开发、各自独立验证**，不必等端到端。

### 2.7 静默推送与后台刷新为什么不能当主方案

- **静默推送**（`apns-push-type: background`）必须 priority 5，官方明确说会被合并、节流、有时**不投递**；它也**唤不醒被用户手动杀掉的 App**。
- **`BGAppRefreshTask`**：调度时机完全由 iOS 决定（学习用户使用习惯），典型间隔是「≥15 分钟」且经常几小时不跑；
  并且要 `UIBackgroundModes` + `BGTaskSchedulerPermittedIdentifiers`，而后者**没有 `INFOPLIST_KEY_*` 对应项**（本项目用 `GENERATE_INFOPLIST_FILE = YES`，
  `project.pbxproj:232/271`，无物理 Info.plist——**未核实**，实施 P4 时须先确认，可能要落地一份真实 Info.plist）。

→ 结论：**它们只能当兜底，不能当「有照片就一定响一声」的通道**。本方案首期不做（§0.2）。

### 2.8 权限是用户随时可撤销的

通知权限不是一次性的：用户可以在设置里关掉。因此**功能必须在「没有权限」时静默退化到现有的 60 秒轮询**，
而不是报错或卡住。App 侧必须能看到这个状态并给出「去系统设置」的入口。

---

## 3. 方案对比与取舍

### 3.1 七个候选

| # | 方案 | 能覆盖「App 已退出/锁屏」吗 | 服务端改造 | iOS 改造 | 结论 |
|---|---|---|---|---|---|
| **A** | **APNs alert 推送（自建）** | ✅ 能 | 新表 + 注册接口 + `node:http2` 客户端 + 触发点 | entitlements + AppDelegate + 权限 + 注册 | **采纳（主）** |
| B | 静默推送 + 本地通知 | ⚠️ 部分（会被节流、杀进程无效） | 同 A，另加静默载荷 | 同 A + 本地通知 | 不做（§2.7） |
| C | `BGAppRefreshTask` 后台轮询 + 本地通知 | ❌（时机不可控） | 无 | Info.plist + 调度 + 本地通知 | 不做（§2.7） |
| D | 第三方推送服务（OneSignal/极光/Expo） | ✅ | 少（调 SDK/HTTP API） | 多一个 SDK | 不做：多账号、多数据出境、**iOS 侧零依赖的约束被破坏** |
| E | Web Push / PWA 通知 | ❌（说的是原生 App） | VAPID + 订阅表 | 无 | 不做 |
| F | 只靠现有前台轮询 | ❌ | 无 | 无 | **保留为保底**，不作为答案 |
| G | 中转（Bark / ntfy / Server 酱） | ✅ | 一个 `fetch` 到一个 URL | 无 | 不做：通知来自别的 App、依赖第三方、**点不开本 App 的那张照片**。若你只想「今天就能用」，这是 1 小时的临时解（§10） |

### 3.2 为什么 A 的成本是可接受的

1. Apple 开发者付费账号**已经有了**：Team `VX3SCAKB5K`（`ios/DEVELOPMENT_TEAM`、`project.pbxproj:230/269`），且已上架。
2. 服务端新增的代码量：一个表 + 一个 120 行的 APNs 客户端 + 一个路由文件 + 一个触发函数。
3. **零新增依赖**（两端都是）。
4. 验证手段齐备（§2.6），不必真机也能把 90% 的路径跑通。
5. 运行成本：每张照片一次 HTTP/2 POST，几百字节；用户量 = 1。

---

## 4. 详细设计：服务端

### 4.1 数据模型

新增两张表（Prisma，字段风格照既有业务表）：

```prisma
/// 一台已注册接收推送的 iOS 设备（一个 App 安装 = 一行）
model PushDevice {
  id            String   @id @default(cuid()) @db.VarChar(50)
  userId        String   @db.VarChar(50)
  user          User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  /// APNs device token（十六进制字符串），全局唯一：同一台设备换账号要改归属
  token         String   @unique @db.Text
  /// "sandbox" | "production"，必须与 token 来源一致，决定用哪个端点与哪把 key
  environment   String   @db.VarChar(16)
  bundleId      String   @db.VarChar(120)   // dev.boxz.felina
  /// 这台安装的稳定 id（App 自己生成、存 Keychain）：用来排除"自己传的不通知自己"
  clientId      String   @db.VarChar(64)
  deviceName    String?  @db.VarChar(100)   // "iPhone 16 Pro"
  systemVersion String?  @db.VarChar(32)
  appVersion    String?  @db.VarChar(32)
  locale        String?  @db.VarChar(16)
  /// 1=启用 0=停用（登出时置 0）。与既有 show/del 一样用 SmallInt 0/1
  enabled       Int      @default(1) @db.SmallInt
  lastSeenAt    DateTime @default(now()) @db.Timestamp()
  createdAt     DateTime @default(now()) @db.Timestamp()
  updatedAt     DateTime @updatedAt @db.Timestamp()

  @@index([userId, enabled])
  @@map("push_device")
}

/// 投递日志：**一张表两个用途** —— 冷却判据 + "我为什么没收到"的排障依据
model PushDelivery {
  id          String   @id @default(cuid()) @db.VarChar(50)
  userId      String   @db.VarChar(50)
  deviceId    String?  @db.VarChar(50)
  imageId     String?  @db.VarChar(50)
  environment String   @db.VarChar(16)
  /// sent | skipped_cooldown | skipped_self | skipped_disabled | failed | pruned
  status      String   @db.VarChar(24)
  httpStatus  Int?
  apnsId      String?  @db.VarChar(64)
  reason      String?  @db.VarChar(64)   // APNs 的 reason（BadDeviceToken/ExpiredProviderToken/...）
  createdAt   DateTime @default(now()) @db.Timestamp()

  @@index([userId, createdAt])
  @@map("push_delivery")
}
```

设计取舍：

- **为什么不把冷却状态放内存**：serverless 每个实例一份内存，冷启动就丢，等于没有冷却。
- **为什么不单独建 `push_state` 表**：`PushDelivery` 顺带承担排障（「到底发没发、APNs 回了什么」），
  与这个项目「失败必须可见」的一贯做法一致（对照 `docs/superpowers/plans/2026-10-07-ios-image-admin.md:338-346`
  「静默 false → 界面上表现为点了保存没反应，现在会明确提示」）。
- **日志会涨**：每次上传最多几行。加一个保留策略（>90 天删除），可以放在 P3，也可以在 `PushDelivery` 上只记
  `sent` / `failed` / `pruned` 而**不记** `skipped_*`（用「最近一条 sent 的时间」当冷却判据）。**首期采用后者**，省一半写。

> ⚠️ migration：本项目用 `prisma migrate`（`package.json:20-21`、Dockerfile 的 `script.sh:3`）。新增表是纯加法，不动既有表。

### 4.2 APNs 客户端（`server/lib/apns.ts`）

职责单一：给「token + environment + payload」发一条推送，返回 APNs 的结果。**不认识业务**。

```
状态（模块级，随函数实例存活）：
  jwtCache: { key: "sandbox"|"production", jwt: string, signedAt: number }   // 50 分钟过期
  sessions: { sandbox?: ClientHttp2Session, production?: ClientHttp2Session }
```

要点：

1. **JWT**：`node:crypto` 的 `createSign('SHA256')` 签 ES256（需 `dsaEncoding: 'ieee-p1363'` 才能得到 JOSE 要的 64 字节裸签名，**不是 DER**）。
   `iat` 用秒；缓存 50 分钟；`kid`/`iss` 来自环境变量。
2. **连接**：`http2.connect('https://api.push.apple.com:443')`，按 `environment` 各一条；监听 `error`/`close`/`goaway`，
   一旦触发就**清掉单例**（下次调用重建）。这是 serverless 里唯一正确的做法——不要试图「保活」。
3. **一次发送** = `session.request(headers)` + `req.end(payload)`；同时监听 `response`（拿 `:status`）、`data`、`end`、`error`，
   并加**硬超时**（2.5 秒）与 `req.close()`，保证失败路径不会挂住函数。
4. **并发**：一次上传只发 1 条；即使一批多台设备，`Promise.allSettled` 即可，不做连接池。
5. **不做**官方那条「每次连接前做未缓存 DNS 查询」的最佳实践——它是为了「大量推送时把流量摊到多台 APNs 服务器」，
   本场景每天几条推送，收益为零，反而增加一次 DNS 往返。（写在这里是为了说明**是权衡后不做，不是不知道**。）
6. **`fetch` 不得出现在这个文件里**（§2.2）。可以加一条 lint/结构测试钉住：`server/lib/apns.ts` 不得出现 `fetch(`。

请求头（照 §2.4）：

```
:method POST
:path   /3/device/<token>
apns-topic        dev.boxz.felina
apns-push-type    alert
apns-priority     10
apns-expiration   <now + 3600>
apns-collapse-id  new-images
apns-id           <自己生成的 UUID，写进 PushDelivery>
authorization     bearer <JWT>
```

载荷（示例）：

```json
{
  "aps": {
    "alert": { "title": "大福映画 Felina Gallery", "body": "「海边日落」刚刚上传" },
    "sound": "default",
    "thread-id": "new-images",
    "interruption-level": "active",
    "mutable-content": 1
  },
  "v": 1,
  "imageId": "clx…",
  "albumValue": "/daily",
  "previewUrl": "https://felina-asset.boxz.dev/images/daily/preview/clx….webp"
}
```

- 标题用 `custom_title`（`server/db/query/configs.ts:58-73 fetchSiteBranding`）。
- 正文由**后台可配的模板** `configs.push_body_template` 渲染（默认 `「{{title}}」刚刚上传`），
  占位符 `{{title}}`（照片标题，空则文件名，再空则「一张新照片」）与 `{{album}}`（相册名）。
  → **2026-10-17 变更**：原先相册名占一个 `subtitle` 位，用户要求去掉；想看相册名就写进模板。
- **不放 `badge`**（不做未读数，见 §10）；**不放原图 `url`**（没必要，且减少载荷）。
- `mutable-content: 1` 现在没有 Extension 会被忽略，是为 P4 的缩略图预留（无副作用）。
- **4 KB 预算**：正文标题最长 200（`Images.title @db.VarChar(200)`），加 URL 与其余字段仍远小于 4 KB；
  但仍要在构造后断言 `Buffer.byteLength(payload) <= 4096`，超了就截断正文——**载荷超限 APNs 直接拒**，不能靠运气。

### 4.3 触发点与执行时机

**不改 `insertImage`**：它在 `$transaction` 里（`server/db/operate/images.ts:20-65`），是 `'use server'` 数据层，通知不是它的事。

**做法**：新增 `server/lib/new-image-notify.ts` 导出 `notifyNewImage(image)`，
在两个入口的**写后副作用块**里各调一次——就是 `revalidateTag` 所在的那两处（`hono/images.ts:26-32`、`hono/admin/index.ts:120-126`），
与缓存失效并列，语义上完全同类。

**用结构性测试钉住「两个入口都必须调」**：仿照既有的 `tests/api/require-session.test.ts:99-131`
（扫描 `hono/` 下注册路由的文件必须出现 `requireSession`）写一条：`hono/images.ts` 与 `hono/admin/api.ts` 必须出现 `notifyNewImage`，
并在文件清单里点名。**这是防「以后新增第三个入口忘了接线」的唯一有效手段**。

> **实现回填（2026-10-13）**：App 那一路最终接在 **`hono/admin/api.ts` 的登记 handler** 里，
> 而不是 `hono/admin/index.ts` 的 `invalidate()`：
> 前者能拿到请求头（`X-Felina-Client-Id`，用于「自己传的不通知自己」）与 context，后者两者都没有。
> 为了不把 `api.ts`（纯工厂，要能在 `node --test` 下跑）变成依赖 Prisma 的模块，
> 它把推送声明成一个 **dep**（`deps.notifyNewImage`），由 `hono/admin/index.ts` 注入真实实现。
> 结构性断言因此改成检查 `hono/images.ts` + `hono/admin/api.ts` + `hono/admin/index.ts`（注入点）三处。

**执行时机**：首期**直接 `await`**（带 2.5 秒硬超时），不用 `after()`/`waitUntil`。理由：

- 全仓库目前**没有任何** `after()`/`waitUntil` 先例（grep 0 命中），引入一个新机制要付学习与验证成本；
- 登记接口本身已经要下载原图 + sharp 生成预览图 + 算 ThumbHash（`server/lib/managed-image.ts:26`），耗时远超推送的 ~200ms；
- **直接 await 让错误可见**（拿得到 APNs 状态码），而 fire-and-forget 在 serverless 里可能被截断。

若 P2 实测发现上传明显变慢，再换成 `after()`（Next 16 的 `next/server` 提供）；届时要注意 OpenNext/Cloudflare 下 `after()` 有已知问题——
但本项目**留守 Vercel**（§1.4），这条不适用。

### 4.4 防刷屏（合并）

单张上传 = 一次登记调用，**不能一图一推**。规则：

1. 查 `PushDelivery` 里该用户**最近一条 `status='sent'`** 的时间；距今小于 `push_cooldown_seconds`（默认 **120**）→ 直接返回，不写日志、不发送。
2. 同一冷却窗口内的多条推送共用 `apns-collapse-id: new-images`（设备离线时 APNs 侧也会合并）。
3. 冷却窗口内的第二次上传**不补推**：用户点开 App 就能看到全部，通知只是「有新东西」的信号。

> 取舍记录：更聪明的做法是「冷却结束时补推一条『共 3 张新照片』」，但那需要定时器/队列（本项目没有，§1.3），
> 不值得为一个计数引入调度设施。**明确记在这里，避免以后有人以为我们忘了。**

### 4.5 「自己传的不通知自己」

- App 生成一个稳定的 `clientId`（Keychain 里的 UUID）并**在登记请求上带 `X-Felina-Client-Id` 头**。
- 服务端在挑选目标设备时跳过 `clientId` 相同的行。
- Web 上传没有这个头 → 不跳过任何设备（**网页上传手机一定会响**，这正是主要场景）。
- 注意：`clientId` 随安装删掉即失效（iOS 删 App 会清 Keychain 项）→ 重装后是新的 `clientId`，**不会误伤**，也不需要清理旧行（`lastSeenAt` 超期的那行会被降级，§4.8）。

### 4.6 API 契约

新增 `hono/push/{api,index}.ts`，挂在 `hono/index.ts` 里 `route.route('/push', push)`（命名空间 `/api/v1/push/*`，
自动继承 `proxy.ts:8-13` 的会话门禁）。

> **2026-10-17 纠正**：`POST /devices` 与 `DELETE /devices` 改成**公开**（不加 `requireSession`），
> 否则"装了 App 的家人/朋友"收不到通知；只有 `GET /devices`（诊断）挂会话。
> ⚠️ 因此 `tests/api/require-session.test.ts` 那条"每个 hono 路由文件都必须挂校验"的结构性断言
> **不能**无脑套到 `hono/push/api.ts` 上 —— 它已经是"部分路由公开"的例外，需要在测试里显式说明。
> 公开写入的三道闸见 §6。

错误格式沿用既有 `{code, message}`（对照 `hono/require-session.ts:26`）。

```http
POST /api/v1/push/devices          # 注册 / 更新（App 每次启动都调，兼当心跳）
  body: { token, environment, clientId, deviceName?, systemVersion?, appVersion?, locale? }
  → 200 { code:200, data:{ id, deviceName, systemVersion, appVersion, environment,
                           enabled:1, clientId, lastSeenAt, tokenSuffix } }
  语义：按 token upsert（token 唯一）；改归属、置 enabled=1、刷新 lastSeenAt
  错误：400 invalid_token / invalid_environment / invalid_client_id / invalid_json；401 authentication_failed

DELETE /api/v1/push/devices?clientId=<id>   # 登出 / 关闭通知时置 enabled=0（不删行，保留排障线索）
  → 200 { code:200, data:{ disabled:<受影响行数> } }

GET /api/v1/push/devices            # 诊断：本用户的设备列表（不返回完整 token，只回后 8 位）
  → 200 { code:200, data:{ pushEnabled:<服务端能不能推>, devices:[ { id, deviceName, systemVersion,
                                     appVersion, environment, enabled, clientId, lastSeenAt, tokenSuffix } ] } }

POST /api/v1/push/send              # 对指定照片手动发一条（后台用）—— **需要登录**
  body: { imageId, body? }          # body 省略 = 用模板渲染；给了也仍做 {{title}}/{{album}} 替换
  → 200 { code:200, data:{ status, sent, skipped, failed } }
  语义：跳过冷却（人主动点的动作）、只允许 public+未删除的图、复用自动触发那套发送逻辑
  错误：400 invalid_request；401 authentication_failed；404 image_not_found；500 push_failed
```

> **实现回填（2026-10-17）**：`POST /devices` 与 `DELETE /devices` 公开（`proxy.ts` 加了唯一放行点：
> 路径精确等于 `/api/v1/push/devices` 且方法不是 GET）；`GET /devices` 与 `POST /send` 需要登录。

> **实现回填（2026-10-13）**：与本文档初稿相比有三处按实现固定下来的差异：
> 1. 请求体**不接受 `bundleId`** —— 它同时是 `apns-topic`，只能由服务端从 `APNS_BUNDLE_ID` 填，
>    让客户端指定等于让客户端决定往哪个 topic 推（zod 会直接丢弃未声明字段）。
> 2. `GET` 的响应多了 `pushEnabled`：它是「总开关 **且** 凭据齐备」的合成结果，
>    App 据此提示"服务端还没开推送"，而不是让用户以为是自己手机的问题。
> 3. 冷却的粒度是**每台设备**（不是每个用户）：日志表按 `deviceId` 查最近一次成功投递。
>    与「广播给所有启用设备」的目标集合是自洽的 —— 一台设备不该因为另一台刚收过就收不到。

约束（照 `hono/admin/api.ts` 的 zod 校验风格）：

- `token`：十六进制、长度 32–200（`String.raw` 正则 `^[0-9a-fA-F]{32,200}$`）——**照最小必要校验，不猜 APNs 的 token 长度**（官方明确说「Don't make assumptions about device token size」）。
- `environment`：只接受 `"sandbox" | "production"`。
- `clientId`：`^[A-Za-z0-9_-]{8,64}$`。
- **不接受** `userId`（从会话取）。单用户站点里这也是对的：**永远不要相信客户端报的身份**。
  实现上把会话放进了 Hono context（`hono/require-session.ts` 的 `c.set('session', …)`），
  所以需要 userId 的路由不必自己再验一次 —— 再验一次既是双倍开销，也给"忘了验、转而相信 body"留了口子。

### 4.7 凭据与配置

| 项 | 放哪 | 键名 | 默认 |
|---|---|---|---|
| `.p8` 私钥内容 | **环境变量**（`\n` 转义；部署时 `replace(/\\n/g,'\n')`） | `APNS_KEY_P8` | 空 = 推送不可用 |
| Key ID（10 字符） | 环境变量 | `APNS_KEY_ID` | 空 |
| Team ID（10 字符） | 环境变量 | `APNS_TEAM_ID` | 空（本机值 `VX3SCAKB5K`） |
| 沙箱专用 key（若 Apple 发的是环境专用 key） | 环境变量（可选） | `APNS_SANDBOX_KEY_P8` / `APNS_SANDBOX_KEY_ID` | 空 = 复用生产 key |
| bundle id | 环境变量（与凭据同组） | `APNS_BUNDLE_ID` | `dev.boxz.felina` |
| 总开关 | `configs` 表 | `push_enabled` | `"false"` |
| 冷却秒数 | `configs` 表 | `push_cooldown_seconds` | `"120"` |
| 通知正文模板 | `configs` 表 | `push_body_template` | `「{{title}}」刚刚上传`（占位符 `{{title}}` / `{{album}}`，渲染见 `server/lib/push-template.ts`） |

**为什么这次不学 R2 把凭据放表里**（`server/lib/preview-storage.ts:26-33` 是既有范例）：
R2 的 secret 已经在库里了，但那是历史选择；`.p8` 是**签名密钥**——拿到它就能给全站设备推任意通知（虽读不到数据，但能冒充官方发消息）。
它不该进 `db-backups/` 的 dump，也不该在设置页有回显路径。**非秘密的开关与冷却放表里**，
这样改行为不用重新部署，也不需要把密钥送到后台界面。

新增 `configs` 键要照既有惯例走完整链路（少一步就会「后台看得见、改不动」或「改了不生效」）：

1. `prisma/seed.ts:5-41 INITIAL_CONFIGS` 加两条（注意 `skipDuplicates`——**只对新库生效**，生产库要手动 INSERT 一次）；
2. 代码默认值兜底：`server/db/query/configs.ts:81-95 fetchConfigValue` 的 `defaultValue`（`push_enabled ?? 'false'`、`push_cooldown_seconds ?? '120'`）——**不能只靠 seed**；
3. 读 + 写：`hono/settings.ts` 加 GET 键列表（照 `:55-66`）与 PUT handler（照 `:107-121`）；
4. 写入实现：`server/db/operate/configs.ts`（照 `:36-52 updateR2Config`）；
5. 后台界面：`app/admin/settings/preferences/page.tsx`（`'use client'` + fetch，**不是 server action**）；
6. i18n：`messages/{zh,zh-TW,en,ja}.json` 的 `Config` 段；
7. **不**暴露到公开 API（`hono/public-api/v1/index.ts:31-40 PUBLIC_CONFIG_KEYS`）——推送配置与客户端无关。

注意 `configs` 读取有 **300 秒跨请求缓存**（`server/db/query/configs.ts:29,46`）：
改了 `push_enabled` 最多 5 分钟才全量生效（除非调 `revalidateTag(CONFIGS_TAG)`——**PUT handler 里要调**，否则「改完没反应」）。

### 4.8 失败与可观测

| APNs 结果 | 处理 |
|---|---|
| `200` | `PushDelivery.status='sent'`，记 `apnsId` |
| `400 BadDeviceToken` / `410 Unregistered` | `PushDevice.enabled=0`（**不物理删**，留痕），`status='pruned'` |
| `403 ExpiredProviderToken` | 清 JWT 缓存并**重试一次**；仍失败记 `failed` |
| `403 TopicDisallowed` / `BadCertificateEnvironment` | 记 `failed` + `reason`：**几乎一定是 environment 与端点/key 配错**（§2.3） |
| `429 TooManyRequests` | 记 `failed`（本场景不该出现） |
| `5xx` | 记 `failed`，不重试（下一次上传自然会推） |
| 网络/超时 | 记 `failed`，清连接单例 |
| 设备 `lastSeenAt` > 90 天 | 视同失效，不发送、置 `enabled=0` |

**硬约束**：`notifyNewImage` **永远不能抛**。整个函数体 `try/catch` 包住，最外层 `console.warn`。
两个调用点也要照既有惯例「副作用失败不影响写」（对照 `hono/images.ts:26-32`、`server/lib/managed-image.ts:58-60`）。
**必须有单测证明：APNs 客户端抛异常时，登记接口仍返回 200。**

日志格式固定，便于捞：

```
[push] sent imageId=clx… device=clx… env=production apnsId=… 
[push] skipped reason=cooldown sinceLast=42s
[push] failed imageId=… reason=BadDeviceToken status=400
```

---

## 5. 详细设计：iOS 端

### 5.1 工程与能力（改 `scripts/ios-project.py`，不手改 pbxproj）

既有约定：**不手工改 `project.pbxproj`**，它由 `scripts/ios-project.py` 生成（entitlements 在 `:469-481` 写出）。

需要改三处：

1. **entitlements 加 `aps-environment`**，并且**按配置分成两份**：
   生成 `FelinaGallery.debug.entitlements`（`aps-environment = development`）与 `FelinaGallery.release.entitlements`（`production`），
   两个 build configuration 各用各的 `CODE_SIGN_ENTITLEMENTS`（`project.pbxproj:355/394` 现在共用一份）。
   **理由**：靠「profile 覆盖」是隐式行为，调试包/发布包搞反时表现为「推送静默不发或 403」，很难查；两份文件让取值显式可见。
2. **Apple Developer 后台**：给 App ID `dev.boxz.felina` 勾上 **Push Notifications** 能力（自动签名会重新生成 profile）。
   这一步**必须人工做一次**，且要在生成工程之前。
3. **P4（可选）** 才需要 `UIBackgroundModes`；`BGTaskSchedulerPermittedIdentifiers` 在 `GENERATE_INFOPLIST_FILE` 下**是否有 `INFOPLIST_KEY_*` 对应项未核实**，P4 开工前先确认（§2.7）。

### 5.2 时机：什么时候要权限（**2026-10-17 纠正**）

```
App 启动（会话恢复完）
   → 首次：requestAuthorization([.alert, .sound])      （只要这两个，不要 .badge：不做角标，§10）
   → 允许  → UIApplication.shared.registerForRemoteNotifications()
   → 拒绝  → 记下状态，静默退化到前台轮询；界面给「去系统设置」入口（UIApplication.openSettingsURLString）
之后每次启动 / 回前台：
   → 不弹框，只是重新 registerForRemoteNotifications()（token 可能被系统轮换）
```

- **不需要登录**。这是对初版的纠正：初版把申请时机放在「登录成功进入管理页」，理由是"启动时弹框同意率低"，
  但那等于**只有站长登录过的手机才收得到通知** —— 与「装了 App 的家人都该收到」的需求正好相反。
- 仍然要考虑**只有一次机会**的问题（iOS 弹窗一辈子只弹一次）：所以只在 `.notDetermined` 时申请，
  已经拒绝就什么都不做（只能去系统设置）；已授权则每次启动静默续一次 token。
- 每次 App 启动（或回前台且超过 24 小时）都做一次**心跳**：拿当前 token 调 `POST /api/v1/push/devices`。
  token 可能变（重装、恢复备份、系统轮换），**不能只在登录时注册一次**。
- 用户关掉通知 / 卸载前 → `DELETE /api/v1/push/devices?clientId=…`（置 `enabled=0`）。
  **注意**：这不再是"登出"的副作用 —— 登出只影响上传/管理，不该让人收不到新照片通知。

### 5.3 注册与保活

- `AppDelegate`（**必须新增**，§2.5）只做两件事：把 `deviceToken: Data` 转成十六进制交给 Kit；把注册失败原因记下来（诊断日志）。
  **它不持有业务逻辑**——Kit 通过一个 actor（`PushRegistrar`）暴露 `register(deviceTokenHex:)`。
- `environment` 判定：`#if DEBUG` → `"sandbox"`，否则 `"production"`。
  （Debug 包的 `aps-environment = development`，拿到的是沙箱 token；TestFlight / App Store 包是 production。二者必须与 §2.3 的端点/key 配对。）
- `clientId`：首次生成 UUID 存 Keychain（复用既有 `KeychainStore`，account 建议 `"push-client-id"`，service 仍是 `dev.boxz.felina`，`KeychainStore.swift:48`）。
  用 Keychain 而不是 `UserDefaults` 的理由与既有会话 Cookie 一致（`AppEnvironment.swift:52` 附近注释：明文、会随备份带走）。
- **注册/停用请求不带 Cookie**：这两个接口是公开的（§4.6）。Kit 里因此**不再注入会话依赖**，
  只有诊断用的 `GET /push/devices` 才带 Cookie。
- 上传 / 登记请求加 `X-Felina-Client-Id` 头（§4.5）。

### 5.4 收到通知怎么办

`UNUserNotificationCenterDelegate`（可放在 AppDelegate 上，`UNUserNotificationCenter.current().delegate = self`）：

| 场景 | 回调 | 行为 |
|---|---|---|
| **前台**收到 | `willPresent` | `completionHandler([])`（不弹）+ 触发 `gallery.pollForUpdates()` 与 `adminList.refreshAfterUpload()`。效果 = 「60 秒轮询」变成「推送即刷新」 |
| **后台/锁屏**点击 | `didReceive` | 取 `userInfo["imageId"]` → 打开那张照片的预览 |
| 冷启动（点通知拉起 App） | 同上，但环境还没就绪 | 把 imageId 存进一个 `PendingRoute`，等 `bootstrap()` + `restoreSession()` 完成后由 `RootView` 消费 |

跳转实现（复用现有结构，不引新机制）：

`RootView` 已有 `@State private var previewTarget: ImageDTO?`（`PicImpactApp.swift:31`）与 `.navigationDestination(item:)`。
所以只需：`imageId` → `GET /api/public/v1/images/:id`（**已存在**，`hono/public-api/v1/index.ts:94`）→ 拿 `ImageDTO` → `previewTarget = dto`。
拿不到（图已隐藏/删除）→ 提示一句，不跳。

**注意**：`public/images/:id` 有 `Cache-Control: public, s-maxage=60`（`hono/public-api/shared.ts:51-54`）+
App 侧已全局 `.reloadIgnoringLocalCacheData`（`docs/superpowers/plans/2026-10-07-ios-image-admin.md:321-324`）——这条既有修复正好是本需求的前提，别退化它。

### 5.5 与现有轮询/缓存的关系（三层，各司其职）

```
第 1 层  推送（新）        → 秒级，覆盖"App 不在前台"
第 2 层  回前台立即查（已有）→ HomeView.swift:150-154
第 3 层  60 秒前台轮询（已有）→ HomeView.swift:67,157-163   ← 权限被拒 / 推送没配好时的保底
```

**第 3 层一行都不改**。推送只是「更快 + 不在前台也知道」，任何推送故障都必须退化到第 2/3 层而不是白屏。
（顺带：`HomeView.swift:155` 的注释写「每 5 秒」而常量是 60 秒，是本轮顺手的注释修正项。）

### 5.6 模块落点与可测性

| 新文件 | 位置 | 为什么放这 |
|---|---|---|
| `PushRegistrar.swift` | `ios/PicImpactKit/Sources/PicImpactKit/Push/` | 纯逻辑：token 十六进制化、`clientId` 生成/持久化、environment 判定、注册请求编码、心跳节流 → **可被 `swift test` 覆盖** |
| `PushClient.swift` | 同上 | 4 个端点的请求构造（仿 `AdminImageClient.swift`） |
| `AppDelegate.swift` | `ios/FelinaGallery/`（**App target，不进 Kit**） | 用了 UIKit；`Package.swift:8` 的 Kit 同时支持 macOS，UIKit 代码放进去会**直接编译失败**（本机 `swift test` 跑的就是 macOS 目标，见 `.build/arm64-apple-macosx`） |
| `PushRoute.swift` | `ios/FelinaGallery/` 或 Kit | `userInfo` → `PendingRoute` 的解析。**解析逻辑放 Kit**（可测），App 只负责消费 |

iOS 侧单测（`scripts/ios-test.sh` → `swift test`）覆盖：`clientId` 生成与持久化、十六进制转换、
`environment` 判定、注册请求体编码、`userInfo → PendingRoute`（含非法/缺字段）、心跳节流。

---

## 6. 安全与隐私

| 风险 | 处理 |
|---|---|
| `.p8` 泄漏 = 任何人可向你的设备推任意通知 | 只在环境变量；key 分环境；怀疑泄漏随时吊销并重建（§2.3 官方给的吊销流程） |
| 设备 token 泄漏 | token 只能决定「往哪台设备推」，不能读数据；DB 里 token 不外显（`GET /push/devices` 只回后 8 位） |
| 伪造/垃圾设备注册（**2026-10-17 变更**） | 注册接口现在是**公开**的（装了 App 就能收通知），所以不再有会话这道门。改为三道闸：`token` 必须是十六进制 32–200、按 token 去重（upsert）、**启用设备上限 2000**（只数 90 天内活过的）。再加自动淘汰：APNs 回 410/BadDeviceToken 就停用该设备，伪造 token 在第一次推送后即被清掉。`userId` 已不再写入 |
| 通知内容泄露未公开图片 | **新登记的图一定是 `show=0`（公开）**（`server/db/operate/images.ts:46-47`）。载荷里**只放已公开的预览图 URL 与标题**，不触发任何额外权限；若显式判断，条件是 `del=0 AND show=0` |
| 登出后仍被推送 | **不会**：登出与"收不收通知"已解绑（登出只影响上传/管理）。要停收只能用系统设置关通知，或调 `DELETE /push/devices` |
| 滥用（刷推送） | 冷却窗口（§4.4）；且入口需要已登录会话 |
| 未授权注册端点 | `POST/DELETE /api/v1/push/devices` 是**有意公开**的（否则家人朋友装完收不到）。只有 `GET /push/devices`（诊断，能看到全部设备的 token 后缀）挂会话 |

---

## 7. 验收（可测量，不靠「看着像」）

### 7.1 服务端单测（`pnpm test:api`，node:test 风格，仿 `tests/api/admin-api.test.ts`）

- [ ] JWT：`alg=ES256`、`kid`/`iss` 取自配置、`iat` 为秒；**50 分钟后再取是新 token，20 分钟内复用旧 token**
- [ ] 载荷：序列化后 `byteLength <= 4096`；超长正文被截断
- [ ] 请求头：`apns-topic == bundleId`、`apns-push-type=alert`、`apns-priority=10`、`path=/3/device/<token>`
- [ ] 冷却：120 秒内第二次调用 → `skipped_cooldown` 且 **APNs 客户端零调用**
- [ ] 自传排除：带同 `clientId` 的设备被跳过
- [ ] 410/BadDeviceToken → 该设备 `enabled=0` 且**不抛**
- [ ] **APNs 客户端抛异常时，登记接口仍 200**（失败隔离的硬断言）
- [ ] `push_enabled != "true"` → 直接返回，零副作用
- [ ] 结构性：`hono/images.ts` 与 `hono/admin/index.ts` 都必须出现 `notifyNewImage`（仿 `tests/api/require-session.test.ts:99-131`）
- [ ] 结构性：`server/lib/apns.ts` 不得出现 `fetch(`
- [ ] `/api/v1/push/*` 三个端点未登录全部 401（沿用 `createAdminApi` 那种依赖注入工厂，不碰真库）

### 7.2 iOS 单测（`scripts/ios-test.sh`）

- [ ] `clientId` 首次生成后稳定；`environment` 在 Debug/Release 下判定正确
- [ ] device token `Data` → 十六进制字符串
- [ ] 注册请求体字段与 §4.6 契约逐字段一致
- [ ] `userInfo` → `PendingRoute`（含缺 `imageId`、类型不对等负例）

### 7.3 端到端（决定性验证，按成本从低到高）

1. **不发服务端**：`xcrun simctl push` 投递 §4.2 的载荷 → 模拟器弹出通知 → 点击 → App 打开到对应预览。**这一步验证了 §5.4 的全部逻辑。**
2. **不发自己的服务端**：用 Apple 的 **Push Notification Console** 直接向真机/模拟器发一条 → 验证真机权限与呈现。
3. **完整链路（模拟器）**：Xcode 14+ 的 Apple Silicon 模拟器能拿真实沙箱 token（§2.6）→ App 注册 → DB 里出现 `push_device` 行 →
   在 **Web 后台上传一张** → **模拟器在 App 退到后台时收到推送** → 点击进入该图。
4. **完整链路（真机 + 生产）**：TestFlight 包（production）→ **手动杀掉 App** → 网页上传一张 → **锁屏收到通知** → 点击唤起并进入该图。
   **这是本需求的最终验收。**
5. **负例（逐条实测并记录）**：
   - 连传 20 张 → **只收到 1 条**（冷却生效）
   - 手机自己上传 → **自己不振**（`clientId` 排除生效）
   - 关掉系统通知权限 → 上传后不报错，App 仍靠轮询刷新
   - 登出 → 不再收到
   - `push_enabled=false` → 上传照常成功，无推送
   - 故意让 `.p8` 写错 → 上传仍然成功（失败隔离），日志有 `[push] failed`
   - 沙箱 token 打到生产端点（或反之）→ 观察到明确的 `reason`，验证 §4.8 的错误分类真的能区分

---

## 8. 分阶段

| 阶段 | 内容 | 完成标志 |
|---|---|---|
| **P0 服务端地基** | `server/lib/apns.ts` + 两张表 + migration + 单测；手工用脚本向一台已注册设备发一条 | 真机/模拟器收到一条**由我们服务端发出**的推送。此阶段 iOS 侧用 Push Console 或临时 `simctl` 拿 token 即可 |
| **P1 iOS 地基** | `scripts/ios-project.py` 两份 entitlements、App ID 勾 Push、`AppDelegate`、权限申请、`clientId`、注册与心跳、登出 | DB 里出现并维持一行健康的 `push_device`；杀掉 App 重开仍然有效 |
| **P2 接线与合并** | `notifyNewImage` 接到两个入口、冷却、自传排除、失败隔离 + 结构测试 | §7.3 第 3/4/5 条全过 |
| **P3 体验与管理** | 前台静默刷新、点击跳转、设置页开关与冷却、`GET /push/devices` 诊断入口、日志保留策略 | 点通知能进到那张图；后台能开关与看设备 |
| **P4（可选）** | 缩略图（新增 Notification Service Extension target） | 通知里带图 |

**建议 P0–P3 一起交付**：P3 之前的体验是「响一声但点进去只到首页」，不完整。

---

## 9. 风险与坑（逐条，含无法回避的）

1. **HTTP/1.1 打不通 APNs**（§2.1）→ 任何 `fetch` 实现都会静默失败。**已用实测钉住**，并在 P0 的测试里加一条「apns.ts 不得出现 fetch」。
2. **sandbox/production 必须成对**：`environment`（token 来源）→ 端点 + key，三者必须一致，否则 `BadDeviceToken` / `TopicDisallowed`。
   调试包与发布包混用时最容易踩（§2.3）。两份 entitlements 是为此。
3. **一条连接绑定 team + bundle**：sandbox 与 production 必须各一条连接；混用会在**第二次**推送才报错，症状极难定位。
4. **serverless 里的 HTTP/2 会话**：实例被冻结/回收时 `ClientHttp2Session` 可能已失效（`GOAWAY`/`close`）。
   必须监听事件并**丢弃单例重建**；不重建的后果是「上线后第一次推送成功、之后全失败」。
5. **JWT 刷新有下限**（20 分钟）：缓存短于 20 分钟去换新 token，同连接上会被 APNs 拒。50 分钟是安全值。
6. **触发点可能被漏接**：将来若有人新增第三个写图片的入口（导入脚本、批量接口）而忘了调 `notifyNewImage` → 静默不推送。
   **唯一防线是 §7.1 的结构性测试。**
7. **冷却会「吞」通知**：120 秒内连续上传只响一声。**这是设计意图**，但要写进用户可见的文案/说明，否则会被当成 bug。
8. **权限可被撤销**：功能必须优雅退化到轮询（§5.5）。**不允许**出现「没权限就卡住/报错」。
9. **老版本 App 收不到**：推送是纯新增，旧版本既不注册也不处理。**必须发新版本**；在用户更新前，这个功能等于不存在。
   与之配套：服务端要能容忍「零个已注册设备」（今天就是这种状态），不能报错。
10. **`.p8` 是一次性下载的**：Apple 只允许下载一次。丢了就吊销重建（并要同步更新 `APNS_KEY_ID`）。**下载后立刻存好**。
11. **`revalidateTag` 那个坑会被复制**：`configs` 有 300 秒缓存，PUT handler 里若不调 `revalidateTag(CONFIGS_TAG, { expire: 0 })`，
    改开关后最多 5 分钟不生效——这个坑本项目已经踩过一次（`docs/superpowers/plans/2026-10-07-ios-image-admin.md:242-245`）。
12. **`push_delivery` 会增长**：每次上传至少一行。首期只记 `sent`/`failed`/`pruned`（§4.1），并预留清理任务。
13. **`CI 不跑 `pnpm test:api`**：`.github/workflows/eslint.yaml` 只跑 `api:verify-contract`（`:31-32`）与 `ios-audit-surfaces.sh`（`:39`），
    `ios-test.sh` 也没有 workflow 跑。**本方案的验证靠本地脚本**，别指望 CI 拦。
14. **公开 API 的 60 秒边缘缓存**：推送到达后客户端必须**绕过缓存**重拉（App 已有全局 `.reloadIgnoringLocalCacheData`，
    这条不能退化，见 `docs/superpowers/plans/2026-10-07-ios-image-admin.md:321-324`）。

---

## 10. 不做清单（明确排除，避免后期扯皮）

| 项 | 原因 |
|---|---|
| 通知角标（badge / 未读数） | 需要「已读」状态，而图片是全局资源、没有每用户读状态（`prisma/schema.prisma:14-38`）。为一个角标建一套状态不划算 |
| 通知里带缩略图 | 需要 Notification Service Extension（新增 Xcode target），工程由脚本单 target 生成。列 P4 |
| 通知分组以外的分类/静音管理 | 单用户单场景，过度设计 |
| 静默推送驱动后台同步 | 不可靠（§2.7），且它带来的收益（省一次点击）小于复杂度 |
| `BGAppRefreshTask` 兜底 | 同上；且 `BGTaskSchedulerPermittedIdentifiers` 在生成式 Info.plist 下**未核实** |
| Web Push / PWA 通知 | 需求是原生 App（§3.1-E） |
| 第三方推送服务 | 多账号、多出境、破坏「iOS 侧零依赖」（§0.2、§3.1-D） |
| 多用户/多站点推送 | 站点是单管理员独占（§1.3）。表结构天然支持，但现在不做权限模型 |
| 「今天就要能响」的中转（Bark / ntfy） | 不是本方案的一部分；若只想临时用，见 §3.1-G 的一句话说明 |

---

## 附 A：本方案的实测记录（2026-10-13，本机）

环境：macOS + Node v25.8.1 + curl（Xcode 已装）。

**① APNs 是否接受 HTTP/1.1**

```bash
$ curl -s -o /tmp/a.txt -w "http_version=%{http_version} code=%{http_code}\n" --http1.1 \
    -X POST https://api.push.apple.com/3/device/00 -H 'apns-topic: com.example.test'
http_version=0 code=000            # 连接层就失败，连 HTTP 响应都没有

$ curl -s -o /tmp/b.txt -w "http_version=%{http_version} code=%{http_code}\n" --http2 \
    -X POST https://api.push.apple.com/3/device/00 -H 'apns-topic: com.example.test'
http_version=2 code=403
{"reason":"MissingProviderToken"}  # 到达了 APNs，只是没带 provider token
```

**② 服务端运行时的两种 HTTP 客户端**

```js
// Node v25.8.1
await fetch('https://api.push.apple.com/3/device/00', { method:'POST', headers:{'apns-topic':'com.example.test'} })
// → TypeError: fetch failed                        ❌ Node 内建 fetch 默认 HTTP/1.1

// node:http2
const client = http2.connect('https://api.push.apple.com:443')
// → status=403 body={"reason":"MissingProviderToken"}   ✅
```

结论：**自建 APNs 客户端必须用 `node:http2`（§4.2）**；`runtime='nodejs'`（`app/api/[[...route]]/route.ts:28`）是前提。
（两次请求都没有携带任何凭据、也没有真实 device token，除了一条必然被拒的请求外没有产生任何副作用。）

**未核实项**（实施时先验证，不要当既成事实）：

- `INFOPLIST_KEY_UIBackgroundModes` 与 `BGTaskSchedulerPermittedIdentifiers` 在 `GENERATE_INFOPLIST_FILE=YES` 下的可行写法（P4 才需要）。
- 本机 Xcode 版本下 Apple Silicon 模拟器是否确实能拿到真实沙箱 token（§2.6 的论坛结论需在本机复现一次）。

---

## 附 B：事实来源

| 结论 | 来源 |
|---|---|
| 新图片入库唯一收敛点 `insertImage`（2 个调用点） | `server/db/operate/images.ts:16,21,57`；`hono/images.ts:56`；`hono/admin/index.ts:89` |
| 两个登记入口与写后副作用（仅 `revalidateTag`） | `hono/images.ts:34,56,57`；`hono/admin/api.ts:166,204`；`hono/admin/index.ts:67,120-126` |
| 新图强制 `show=0 / show_on_mainpage=0` | `server/db/operate/images.ts:44-47` |
| iOS 靠 60 秒前台轮询发现新图 | `HomeView.swift:67,150-154,157-163`；`GalleryStore.swift:144-158` |
| iOS 无任何推送/后台能力 | `FelinaGallery.entitlements:5-8`；pbxproj 全文；全仓 grep 0 命中 |
| 无 AppDelegate、纯 SwiftUI 生命周期 | `PicImpactApp.swift:6-25` |
| 无稳定设备标识、会话 Cookie 在 Keychain | `AuthStore.swift:26,74-78,177-197`；`KeychainStore.swift:48` |
| 工程由脚本生成、entitlements 由脚本写出 | `scripts/ios-project.py:34-40,354-379,469-481` |
| Team / bundle / 部署目标 | `project.pbxproj:193,213,230,253,269,292`；`ios/DEVELOPMENT_TEAM` |
| 会话中间件与 401 形状 | `hono/require-session.ts:26,33-41,48-53` |
| 配置读写与 300 秒缓存 | `server/db/query/configs.ts:11,29,46,81-95`；`server/db/operate/configs.ts:36-52`；`hono/settings.ts:55-66,107-121` |
| 设置页是客户端 fetch、非 server action | `app/admin/settings/preferences/page.tsx:35,37,60`；`components/admin/settings/storages/r2-edit-sheet.tsx:25,33` |
| 公开只读 API 与 `images/:id` | `hono/public-api/v1/index.ts:94,119`；`hono/public-api/shared.ts:20,51-54` |
| 测试与 CI 现状 | `package.json:27,28`；`tests/api/admin-api.test.ts:22-23`；`tests/api/require-session.test.ts:99-131`；`.github/workflows/eslint.yaml:31-32,39` |
| 部署 = Vercel(sin1) + Supabase；Node 运行时 | `vercel.json:3-5`；`README.md:42,46`；`app/api/[[...route]]/route.ts:27-28` |
| Cloudflare 迁移 no-go | `docs/superpowers/plans/2026-10-07-cloudflare-migration.md:3-5,17` |
| APNs：HTTP/2、端点、头、4KB、push-type | [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)（官方，已核全文） |
| APNs：ES256 JWT、20–60 分钟刷新、key 分环境、连接绑定 team+bundle | [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)（官方，已核全文） |
| 模拟器可注册沙箱 APNs | [Apple 论坛 thread/796868](https://developer.apple.com/forums/thread/796868)（含「Mac 虚拟机里拿不到 token」的例外） |
| 官方推送测试控制台 | [Testing notifications using the Push Notification Console](https://developer.apple.com/documentation/usernotifications/testing-notifications-using-the-push-notification-console) |
| `UIBackgroundModes` 的定义与获取方式 | [UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes) |
| HTTP/1.1 打不通 APNs、`fetch` 打不通、`node:http2` 通 | 本机实测，附录 A |
