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
