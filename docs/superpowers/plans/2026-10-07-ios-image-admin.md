# iOS 接入 web 的图片管理与上传 实施计划

目标：让 App 能像 web 后台一样**管理图片**（列表、删除）并**上传新照片**，且上传不受
Vercel 请求体上限约束。

前置：`2026-10-07-ios-admin-login.md` 已完成（三击标题 → 登录 → 会话存 Keychain）。
本计划直接复用那套会话（Cookie + Keychain）。

## Global Constraints

- **接口位置**：本项目有 Hono 路由挂在 `app/api/[[...route]]`，新接口加在这里（沿用既有中间件与鉴权模式），
  **不要**新起一套 Next Route Handler 风格。
- **不要复用 web 的上传实现**：web 后台的上传与列表是 **server action**（`app/admin/upload/page.tsx`、
  `app/admin/list/page.tsx` 内 `'use server'`），原生 App 无法调用，必须新增 HTTP 接口。
- **上传必须直传 R2，不得经 Vercel 函数中转**：单张原图约 **3.4MB**，而 serverless 函数的请求体上限是个位数 MB，
  中转的话单张都勉强、更不可能批量。做法：服务端只签发**预签名 URL**（请求体极小），App 直接 `PUT` 到 R2。
- **原生 App 不受浏览器 CORS 限制**，因此直传不需要为 CORS 做额外配置（这点与 web 直传不同）。
- **存储凭据**在数据库 `configs` 表里（`r2_accesskey_id` / `r2_accesskey_secret` / `r2_account_id` /
  `r2_bucket` / `r2_storage_folder` / `r2_public_domain`），既有代码 `server/lib/s3api.ts` 已经能构造客户端，
  新接口应**复用**它，不要另写一套。
- **元数据字段**（`server/db/operate/images.ts` 的 `insertImage` 需要）：
  `url` / `preview_url` / `blurhash` / `width` / `height` / `exif` / `labels` 等，另有本项目自身的约定
  `show` 与 `show_on_mainpage` 必须显式写 `0`（不是依赖默认值）。
- **图片必须同时有原图与预览图**：web 上传时会生成约 0.3 倍率的压缩图（预览图），列表页只加载预览图。
  App 上传也必须产出预览图，否则 web 与 App 的列表都会加载原图（很慢）。
- 沿用既有 iOS 约定：SwiftUI + iOS 17 + Swift 6 严格并发；复用 `DesignSystem/`；
  不手工改 `project.pbxproj`；**不 push**。

## Review Focus

1. **预签名 URL 的权限与时效**：只允许写、只允许写进指定前缀、有效期要短，且**必须校验登录会话**——
   这是本批次唯一新增的"能写数据"的入口，签错等于把存储桶开放给任何人。
2. **部分失败**：图片已 PUT 成功、但登记元数据失败 → R2 里会留下**孤儿对象**。要有明确的处理策略
   （至少记录日志 + 允许重试登记，不要静默吞掉）。
3. **元数据保真**：App 生成的宽高/预览图/EXIF 与 web 生成的是否一致。若不一致，会表现为同一张图在
   web 与 App 上显示效果不同（这是最容易漏、也最容易被用户一眼看出的问题）。
4. **客户端算还是服务端算**：预览图与 blurhash 由谁生成。服务端算意味着函数要下载原图并跑图像处理
   （CPU/内存/超时风险）；客户端算则无此风险，但 iOS 侧要自己实现编码与（可能的）blurhash。
   这个取舍必须在计划里定死，不要两边都做一半。

## Task 1: 摸清并写死 API 契约

- 读 `server/lib/s3api.ts`、`server/lib/preview-storage.ts`、`server/db/operate/images.ts`，
  以及 `app/api/[[...route]]` 现有的路由与鉴权中间件。
- 产出契约（端点、方法、请求/响应体、错误码），写回本文件。
- 验收：契约里每个字段都能在既有代码里找到出处，不臆造。

## Task 2: 预签名上传接口

- 端点建议：`POST /api/admin/uploads/sign`，请求体只含文件名/内容类型/大小，响应为预签名 PUT URL + 最终访问 URL。
- 必须校验会话；必须限制前缀与时效。
- 验收：单测覆盖"未登录被拒"、"路径穿越被拒"、"正常签发"三类；并用 curl 实测签发出的 URL 能 PUT 成功。

## Task 3: 登记元数据接口

- 端点建议：`POST /api/admin/images`，请求体为 Task 1 定下的元数据集合。
- 必须校验会话；必须显式写 `show: 0` 与 `show_on_mainpage: 0`。
- 验收：curl 实测插入成功后，**web 首页/相册能立刻看到这张图**（缓存按既有 revalidate 周期）。

## Task 4: 管理列表与删除接口（App 侧管理页用）

- 端点建议：`GET /api/admin/images?page=` 与 `DELETE /api/admin/images/:id`。
- 只返回管理页需要的字段，不要复用公开接口（公开接口不含 `del` 等状态）。
- 验收：curl 实测；删除采用既有软删除约定（`del` 字段），确认 web 与 App 同步消失。

## Task 5: iOS 上传管线

- 选图（`PhotosPicker`，**支持多选**）→ 逐张处理 → 直传 R2 → 登记元数据 → 刷新画廊。
- 处理内容按 Task 1/Review Focus 4 的结论确定（原图 + 预览图 + 宽高 + EXIF + labels）。
- 上传要有进度与失败重试；失败要能看出**是哪一张**失败、失败在哪一步。
- 验收：模拟器上真传一张，**web 端能看到**，且 App 列表随之更新。

## Task 6: iOS 管理页

- 把现在的占位管理页换成真正的列表：缩略图 + 标题/日期 + 删除。
- 验收：模拟器上删除一张，web 端同步消失。

## 本批次验收

1. `xcodebuild` `BUILD SUCCEEDED`；`scripts/ios-test.sh` 全过；新增的 Hono 接口有单测。
2. 模拟器上**真传一张原图（>10MB）成功** —— 这是"绕过请求体上限"这一设计目标的**决定性验证**：
   如果走中转，这个用例必然失败。
3. 该图在 **web 端**可见（首页/相册），缩略图用的是预览图。
4. 该图在 **App 管理页**可见，且能删除；删除后 web 端同步消失。
5. 孤儿对象场景有明确行为（可复现一次：让登记接口故意失败，确认 R2 里留下的对象可被识别/清理）。

## 后续批次（不在本计划内）

- 批量上传的并发与带宽控制、断点续传
- 相册归属与标签的编辑
- 视频 / Live Photo 上传
