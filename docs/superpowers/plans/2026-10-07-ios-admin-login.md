# iOS 管理入口（三击标题 → 登录 → 管理界面）实施计划

目标：让 App 具备"进入管理端"的能力，作为后续上传功能的地基。
入口必须**不干扰普通浏览**：连续点击标题三次才出现登录界面。

本批次只做**地基**：登录、会话持久化、登出入口。**不做上传、不做图片列表**（见文末后续批次）。

## Global Constraints

- **服务端契约（已实测确认，不得改用别的路径）**：`POST https://felina.boxz.dev/api/auth/sign-in/email`，
  请求体 `{"email","password"}`。实测依据：字段缺失时服务端返回 400，报错文本明确写出
  `[body.email] Invalid input: expected string`、`[body.password]` —— 路径、方法、字段名三者由此确定。
- **认证方式是 Cookie 会话**（better-auth）。其插件列表为 `twoFactor` / `passkey` / `customSession`，
  **没有 bearer 插件**，因此不要设计成 Bearer token 方案。
- 该管理员账号**未开启两步验证**（`two_factor` 表 0 行），邮箱+密码一步即可完成登录。
- 会话凭据存 **Keychain**，不得用 `UserDefaults`（后者是明文 plist）。
- SwiftUI + iOS 17，Swift 6 严格并发（注意 `Sendable`、`@MainActor`）。不引入第三方依赖。
- 界面**复用**现有设计系统（先读 `PicImpactKit/.../DesignSystem/`），不自创视觉语言。
- 网络层**复用** `Networking/APIClient.swift`（已有 `baseURL` 与结构化错误 `.http(status:code:message:)`），
  不另起一套 URLSession。
- Xcode 工程由 `python3 scripts/ios-project.py` 生成，**不手工改 `project.pbxproj`**；
  `ios/DEVELOPMENT_TEAM` 与其 skip-worktree 机制不得触碰。
- **不 push**（本批次属 iOS 线，按约定只本地提交）。

## Review Focus

评审时重点看这四处，它们是本批次真正有风险的地方：

1. **Cookie 的存取与携带**：登录响应里的 `Set-Cookie` 如何解析、如何存进 Keychain、
   后续请求如何带上。这里错了会表现为"登录成功但马上又像没登录"。
2. **Keychain 的可访问性等级**：默认 `kSecAttrAccessibleWhenUnlocked` 在后台刷新时可能取不到，
   需要明确选一档并说明理由。
3. **三击手势与滚动的冲突**：标题在滚动容器内，`onTapGesture(count: 3)` 不能破坏滚动、
   也不能让单击/双击变迟钝。要实际在模拟器上滑一滑确认。
4. **失败路径**：密码错、网络断、服务端 5xx、会话过期四种情况各自显示什么。
   尤其是"服务端返回的错误信息要原样展示"—— 这是本批次联通性的证据。

## Task 1: 标题三击手势

- 落点：`PicImpactKit/.../Features/Home/GalleryHeader.swift`
- 做法：在标题区域加 `onTapGesture(count: 3)`，触发一个由上层注入的回调（不要在 header 内部直接持有认证状态，
  保持它是个纯展示组件）。
- 验收：模拟器上连点三次能触发回调（先用打印/断点证明，再接到登录界面）；滑动列表仍然顺畅。

## Task 2: AuthStore（会话状态与登录动作）

- 落点：新建 `PicImpactKit/.../Networking/AuthStore.swift`（或同级 `Auth/` 目录）
- 状态：`isSignedIn` / `currentUser` / `isWorking` / `errorMessage`
- 动作：`signIn(email:password:)`、`signOut()`、`restoreSession()`
- 依赖：注入 `APIClient`；会话读写注入一个 `SessionStorage` 协议（便于单测替换）
- 验收：单测覆盖成功、401（密码错）、网络错误三种分支的状态迁移。

## Task 3: Keychain 会话存储

- 落点：新建 `Auth/KeychainStore.swift` + `SessionStorage` 协议
- 内容：写入/读取/删除一个 `Data`（会话 Cookie）
- 验收：swift-testing 单测做一轮写入→读取→删除→再读取为空的往返。

## Task 4: 登录界面

- 落点：新建视图（放在 `PicImpactKit` 或 App target 均可，说明选择理由）
- 内容：邮箱输入（`.textContentType(.username)`）、密码输入（`.textContentType(.password)`）、
  登录按钮（进行中禁用 + 指示）、错误信息区
- 风格：复用设计系统的纸张色/描边/主色与既有控件
- 验收：错误密码时，**服务端返回的原文**显示在界面上（不是本地编的"登录失败"）。

## Task 5: 占位管理界面与入口挂载

- 落点：新建占位管理页；`ios/FelinaGallery/AppEnvironment.swift` 挂上 `AuthStore`；
  `ios/FelinaGallery/PicImpactApp.swift` 加 sheet/fullScreenCover 承载
- 内容：显示当前账号（邮箱/名称）+ 登出按钮；登出后回到首页
- 行为：已登录时三击**直接进管理页**，不再要求重新登录
- 验收：登出后 Keychain 里确实没有会话；重启 App 后若 Keychain 仍有有效会话，则三击直接进管理页。

## 本批次验收

1. `xcodebuild` 编译通过（必须有 `BUILD SUCCEEDED`）。
2. 在 iPhone 17 Pro Max 模拟器（`89E4FEC2-E7B3-4F1B-8E9C-5D56EF1A9A79`，显式 UDID，禁用 `booted`）上运行。
3. 三击标题 → 登录界面出现。
4. 提交**错误密码** → 界面显示**服务端返回的**错误原文（端到端联通性证据）。
5. swift-testing 单测覆盖：Cookie 解析/存取、Keychain 往返、请求体构造，全部通过。
6. **真实密码登录成功**由用户本人在设备/模拟器上确认（见下）。

> 第 6 项是刻意的分工：实施者**没有也不应该去找管理员密码**，
> 因此"登录成功后进入管理页"这条只能由用户确认，实施者必须如实标注为未验证。

## 后续批次（不在本计划内）

**图片上传**。设计方向已经明确，此处只记录结论，避免下一批次重新论证：

- 单张原图约 **3.4MB**，而 Vercel 函数的请求体上限是个位数 MB —— 走服务端中转的话，
  **一次请求传一张都紧张**，更不可能"一次传很多张"。
- 因此上传应走 **iOS 直传对象存储（R2）**：服务端只负责签发**预签名 URL**（请求体极小），
  图片本体直接 PUT 到 R2，不经过 Vercel 函数。这样单张大小和单批数量都不再受该上限约束。
- （待核实项：Vercel 请求体上限的准确数值与现行文档，本计划不引用未核实的数字。）

---

## 实施结果（回填）

提交：`0364bf8 feat(ios): 管理入口地基（三击标题 → 登录 → 占位管理页）`（本地，未 push）。

### 通过的命令与关键行

```
xcodebuild -project ios/FelinaGallery.xcodeproj -scheme FelinaGallery -configuration Debug \
  -destination 'platform=iOS Simulator,id=89E4FEC2-E7B3-4F1B-8E9C-5D56EF1A9A79' \
  -derivedDataPath ios/DerivedData build            → ** BUILD SUCCEEDED **
scripts/ios-test.sh                                  → 198 tests / 31 suites passed (6.380s)
xcrun simctl install <UDID> …/大福映画.app            → INSTALLED ok
xcrun simctl launch  <UDID> dev.boxz.felina          → pid 4378（保持运行，用户可直接上手）
```

### 验收对照

| 本批次验收项 | 结果 |
|---|---|
| 1. 编译通过 | ✓ `BUILD SUCCEEDED` |
| 2. 指定 UDID 运行（禁用 `booted`） | ✓ 全程显式 UDID |
| 3. 三击标题出登录界面 | ✓ XCUITest 合成真实触摸 + accessibility 断言 + OCR |
| 4. 错误密码显示服务端**原文** | ✓ 显示 `Invalid email or password`（better-auth 原文） |
| 5. 单测覆盖 Cookie/Keychain/请求体 | ✓ 198 tests 全过 |
| 6. 真实密码登录成功（用户确认） | ✓ **已由用户实际操作并观察**：管理页显示 `邮箱 me@boxz.dev`、`昵称 admin`；冷启动后三击直接进管理页 |

第 6 项的意义超出预期：它同时验证了「Keychain 存会话 → 启动时 `get-session` 校验 → 已登录直接进管理页」整条链路。

### 实施中发现并修掉的一个隐蔽缺陷

原设计依赖 `URLSession` 自动把 `Set-Cookie` 收进 `httpCookieStorage` 再读取。用本地 HTTP 服务做验证时发现：
**该存储在测试进程里始终为空**（`URLSession.shared` 亦然），也就是"Cookie 是否真的被收下"无法验证，
而真错了的症状是「登录成功却马上像没登录，且不报任何错」。

改为自行解析响应头的 `Set-Cookie`（注意 Foundation 会把多条 Cookie 用 `, ` 拼成一条，而 `Expires` 自带逗号，
故只在"逗号后紧跟新的 `名字=`"时才切分），并显式关闭 URLSession 的 Cookie 管理 —— 存（Keychain）与带
（显式 `Cookie` 头）均由客户端自己负责。该测试现在覆盖了登录成功的 HTTP 路径。

### 界面调整（用户反馈后）

- 删除登录页整句提示 `连续点击首页标题三次才会出现这个入口。`（入口须隐蔽，页面上不得有任何提示）
- 删除管理页整句 `这里是占位页：图片上传与图片列表还没有实现。`
- 错误文案由 `服务端返回 401：Invalid email or password（INVALID_EMAIL_OR_PASSWORD）`
  收敛为 `Invalid email or password`（只显示服务端原文，状态码与内部 code 不进界面）
- 页标题改用与详情页 `PreviewTitleBlock` 一致的 20pt 粗体 + 青色短横；错误框移到按钮**下方**，
  使其出现/消失时输入框与按钮不位移；去掉两处装饰图标与虚线分隔线

### 未验证（如实）

- 界面是否"好看"未经审美确认（实施者与执行代理都无法看图；所有"屏幕文字"均来自 Vision OCR + accessibility 断言）
- `kSecAttrAccessibleAfterFirstUnlock` 的 iOS 分支未单独断言；**真机**（非模拟器）上的跨启动恢复未测
- 上传相关一律未做

### 已验证但尚未决定的两件

- 构建会触发「生成打包种子」阶段，从线上刷新 `ios/FelinaGallery/Resources/Seed/`（本次刷到 **58 张**，
  仓库里提交的是 56 张）—— 是否把刷新后的种子一并提交，待决定
- 实施过程中临时使用的 UI 测试工程（`/tmp`，未进仓库）证明有价值（它抓出了"三击手势吃掉滚动"的回归）。
  是否正式加一个 UI test target 进仓库，需要改 `scripts/ios-project.py`（目前只生成 App target），待决定。
