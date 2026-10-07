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
4. **客户端算还是服务端算** —— **已定死：预览图与 blurhash 都归服务端**（见文末「Review Focus 4 的裁决」）。
   客户端（web 与 iOS）只上传原图 + 送元数据，不生成预览图、不生成 blurhash。

## Review Focus 4 的裁决（2026-10-07 定稿）

**结论：预览图与 blurhash 都由服务端生成，客户端两边都不做。**

理由（关键是"服务端反正已经必须下载一次原图"）：

1. **预览图的职责早就收归服务端了**，不是这次才决定。`hono/images.ts` 的 `attachManagedPreview`
   在入库时无条件调用 `server/lib/preview-storage.ts` 的 `ensureManagedPreviewUrl()`：
   它 **fetch 原图 → sharp 缩到最长边 800 的 webp（q76）→ PUT 回同桶 `/preview/` 目录 →
   用原图真实显示尺寸回写 width/height**（含 EXIF 方向纠正，见 `server/lib/thumbnail.ts:45,78`）。
   web 上传页现在传的 `preview_url` 是**空串**（`components/admin/upload/multiple-file-upload.tsx:157`
   有注释），就是为了让服务端接管。iOS 若自己生成，就会与 web 走两套规则。
2. **blurhash 现在确实是"客户端算"**（`lib/utils/blurhash-client.ts` 里的 ThumbHash），
   但服务端**已经有一个没人用的等价实现**（`lib/utils/blurhash-server.ts` 的 `encodeThumbHash`，
   同样是 sharp 缩到 ≤100px + `rgbaToThumbHash` + base64）。
   既然服务端为了预览图**已经下载了原图字节**，顺路算一次 ThumbHash 的成本只有 ~10ms 的 100px 缩放，
   不引入任何新的下载/超时风险。
3. **一致性**（Review Focus 3）：由服务端统一算，同一张原图在 web 与 App 上必然得到同一份
   `preview_url` / `width` / `height` / `blurhash`。若让 iOS 自己算，就会出现"同一张图两端显示不同"。
4. **iOS 侧成本**：Swift 里没有 ThumbHash 实现，自己写要几百行且容易与 web 有细微差异；
   而本项目又不允许引入第三方依赖。服务端算 = iOS 侧这块工作量归零。

**因此客户端传的 `preview_url` / `blurhash` / `width` / `height` 只作为兜底**：
服务端算得出来就覆盖（`attachManagedPreview` 现在的行为），算不出来（例如下载失败）才用客户端的值。
`POST /api/v1/admin/images` 的请求体里**不接受** `preview_url` 与 `blurhash` 这两个字段（传了也会被忽略）。

## Task 1: 摸清并写死 API 契约

- 读 `server/lib/s3api.ts`、`server/lib/preview-storage.ts`、`server/db/operate/images.ts`，
  以及 `app/api/[[...route]]` 现有的路由与鉴权中间件。
- 产出契约（端点、方法、请求/响应体、错误码），写回本文件。
- 验收：契约里每个字段都能在既有代码里找到出处，不臆造。

## Task 1 产出：写死的 API 契约（2026-10-07 定稿）

契约里每个字段都能在既有代码里找到出处，出处写在括号里。

### 0. 命名空间、鉴权与错误格式

- **前缀用 `/api/v1/admin/*`，不用计划初稿的 `/api/admin/*`。**
  理由：`proxy.ts:8` 的中间件只对 `/api/v1`（和 `/admin` 页面）做会话门禁；挂在 `/api/v1` 下就**原样沿用**了
  这道门禁与它的 401 形状（`{"success":false,"message":"authentication failed"}`，见 `proxy.ts:9-12`），
  不必去改 proxy 的 matcher 与规则。而 `/api/v1` 本来就是"Web 后台自己调用的写接口"命名空间
  （`/api/v1/images/add`，调用点 `components/admin/upload/multiple-file-upload.tsx:131`）。
- ⚠️ **中间件只做"cookie 在不在"的检查，不验签**：`proxy.ts:5` 用的 `getSessionCookie()`
  （`better-auth/cookies`）只是把 cookie 解析出来返回，不校验签名，也不查库。
  所以三个新端点**在路由内部再用 `auth.api.getSession({ headers })` 真正校验会话**
  （`server/auth/index.ts` 导出的 `auth`）——这是本批次唯一新增的"能写数据"的入口，不能只靠那道门禁。
  （既有的 `/api/v1/*` 写接口都只有中间件那一层，属于既有缺口，本次不动，只在汇报里指出。）
- 错误响应统一为 `{"code": <http status>, "message": "<可读文案>"}`，HTTP 状态码一致。
  实现方式是抛带 `res` 的 `HTTPException`（Hono 4 支持 `options.res`），这样不依赖
  `hono/index.ts:8` 的 onError 分支怎么处理。

### 1. `POST /api/v1/admin/uploads/sign` —— 签发预签名 PUT URL

请求体（`server/lib/admin-api.ts` 的 `signSchema` 校验）：

| 字段 | 类型 | 必填 | 出处/说明 |
|---|---|---|---|
| `filename` | string(1..200) | ✅ | 只用来**取扩展名**。对象名由服务端生成（`@paralleldrive/cuid2` 的 `createId()`，与 `lib/utils/file.ts:92` 的 `const imageId = createId()` 同一做法） |
| `contentType` | string(1..100) | ✅ | 必须以 `image/` 或 `video/` 开头 |
| `albumValue` | string(1..200) | ✅ | 形如 `/daily`，取自 `albums.album_value`（`prisma/schema.prisma` 的 `Albums.album_value`；本库现有值只有 `/daily`）。必须能在库里查到且 `del = 0`，否则 400 |
| `size` | number | ❌ | 仅用于拒绝明显超限的上传。**注意：PUT 预签名 URL 无法在服务端强制大小**（`server/lib/s3api.ts:6` 的 `PutObjectCommand` 没有 content-length 条件），所以这只是"客户端诚实上报"的软限制，契约里不承诺硬保证 |

响应 200：

```json
{
  "code": 200,
  "data": {
    "key": "images/daily/clx1234abcd.heic",
    "uploadUrl": "https://<account>.r2.cloudflarestorage.com/<bucket>/images/daily/clx1234abcd.heic?X-Amz-...",
    "publicUrl": "https://felina-asset.boxz.dev/images/daily/clx1234abcd.heic",
    "contentType": "image/heic",
    "expiresInSeconds": 900
  }
}
```

- `key` 的目录规则**与 web 完全一致**，抽成 `server/lib/upload-key.ts` 的 `buildUploadKey()`：
  `${storage_folder}${albumValue}/${cuid}.${ext}`（`hono/file.ts:63-67` 的既有拼法；`storage_folder`
  与 `bucket` 来自 `configs` 表的 `r2_storage_folder` / `r2_bucket`，读取键见
  `server/lib/preview-storage.ts:25` 的 `R2_CONFIG_KEYS`）。
- `uploadUrl` 由 `server/lib/s3api.ts:6` 的 `generatePresignedUrl(client, bucket, key, contentType, 'put', 900)`
  生成；client 由 `server/lib/r2.ts:6` 的 `getR2Client(configs)` 构造（**复用，不另写 S3 客户端**）。
  有效期 **900 秒**（既有默认值是 3600；写接口用更短的有效期，见 Review Focus 1）。
- `publicUrl` = `${r2_public_domain}/${key}`（`hono/file.ts` 的 `/getObjectUrl` 对 r2 的算法一致）。
- 错误：`400 invalid_filename / invalid_content_type / unknown_album / file_too_large`、
  `401 authentication_failed`、`500 storage_not_configured / sign_failed`。
- **只签名 R2**：本库 `configs` 里 S3 相关键全为空（`accesskey_id`/`bucket`/`endpoint`/`storage_folder`
  实测为空字符串），站点只用 R2。请求体不接受 `storage` 选择，避免又开一个可写前缀。

### 2. `POST /api/v1/admin/images` —— 登记元数据

请求体（`registerSchema` 校验；字段名与类型取自 `types/index.ts` 的 `ImageType` 与 `insertImage`
需要的入参 `server/db/operate/images.ts:12`）：

| 字段 | 类型 | 必填 | 出处 |
|---|---|---|---|
| `albumValue` | string | ✅ | `insertImage` 里写进 `images_albums_relation.album_value`（`server/db/operate/images.ts:47-52`） |
| `url` | string | ✅ | 原图公开 URL。必须是 `${r2_public_domain}/` 开头，否则 400（防止让服务端去 fetch 任意 URL —— `ensureManagedPreviewUrl` 会真的去下载它，`server/lib/preview-storage.ts:145`） |
| `imageName` | string? | ❌ | `Images.image_name` |
| `title` / `detail` | string? | ❌ | `Images.title` / `Images.detail` |
| `labels` | string[]? | ❌ | `Images.labels`（Json） |
| `exif` | object? | ❌ | `Images.exif`（Json）；`exif.data_time` 会被 `normalizeExifDateTime` 规范化（`hono/images.ts:96`） |
| `lat` / `lon` | string? | ❌ | `Images.lat/lon`。缺省时写 `''`（**不能**让 `insertImage` 里 `String(image.lat)` 变成字符串 `"undefined"`） |
| `width` / `height` | int>0? | ❌ | 仅兜底：服务端会用原图真实显示尺寸覆盖（`server/lib/preview-storage.ts:170-175`） |
| `type` | 1\|2? | ❌ | `Images.type`（1=普通图片，2=livephoto），默认 1 |

**不接受**：`preview_url`、`blurhash`、`show`、`show_on_mainpage`、`del`、`sort`、`id`
（zod 的 `z.object()` 会丢掉未声明字段，所以客户端塞了也不生效）。

响应 200：

```json
{
  "code": 200,
  "data": {
    "id": "clx...",
    "url": "https://felina-asset.boxz.dev/images/daily/clx....heic",
    "previewUrl": "https://felina-asset.boxz.dev/images/daily/preview/clx....webp",
    "width": 4032, "height": 3024, "blurhash": "1QcSHQRnh493V4dIh4eXh1h4kJUI",
    "albumValue": "/daily", "show": 0, "showOnMainpage": 0
  }
}
```

- `show` / `show_on_mainpage` **由服务端显式写 0**：`server/db/operate/images.ts:34-40` 已经这么做了
  （那段的注释解释了为什么两个都要显式写）。新路由再把 `show: 0, show_on_mainpage: 0` 显式传进
  插入依赖，让这条约束在**新代码里也看得见**、并且可被单测钉住。
- 可见性判据（"web 端能看到"）= `del = 0 AND show = 0 AND show_on_mainpage = 0`
  （首页查询 `server/db/query/images.ts:185-196`；相册页同理再加上 `albums.del = 0`）。
- 缓存失效沿用 `hono/images.ts:29` 的 `invalidateImages()`（`revalidateTag(IMAGES_TAG)`）。

### 3. `GET /api/v1/admin/images?page=&pageSize=&album=&show=` —— 管理列表

- 查询复用 `server/db/query/images.ts:36` 的 `fetchServerImagesListByAlbum()` 与
  `:111` 的 `fetchServerImagesPageTotalByAlbum()`（它们已经过滤 `del = 0`，并按 `album`/`showStatus` 过滤）。
- `page` 默认 1、`pageSize` 默认 24（夹在 1..60）、`album` 默认空（全部）、`show` 默认 -1（全部；
  0=已公开、1=未公开，语义见 `server/db/query/images.ts:30` 的注释）。
- 响应：`{"code":200,"data":{"page":1,"pageSize":24,"total":58,"hasMore":true,"items":[...]}}`，
  `items[]` 每条只含管理页用得上的字段：
  `id / url / previewUrl / title / detail / width / height / show / showOnMainpage / labels /
  createdAt / albumValue / albumName / exif{model,lensModel,dataTime}`。
  **不复用公开接口的 DTO**（`hono/public-api/v1/serialize.ts` 不含 `show`/`showOnMainpage` 这类状态）。

### 4. `DELETE /api/v1/admin/images/:id` —— 软删除

- 调用 `server/db/operate/images.ts:63` 的 `deleteImage(id)`：`del = 1` + 删除
  `images_albums_relation` 关系（**既有软删除约定**，不是物理删除；R2 对象不删）。
- `id` 只允许 `[A-Za-z0-9_-]{1,50}`（`Images.id` 是 `cuid()` 的 `VarChar(50)`）。
- 响应：`{"code":200,"data":{"id":"clx...","deleted":true}}`，随后 `invalidateImages()`。
- 删除后 web 与 App 都不再出现（查询一律带 `del = 0`）。
- ⚠️ **R2 里的原图与预览图不会被删除**（既有行为，web 删除也一样）。这是"孤儿对象"的另一半，
  在本批次只记录、不处理。

### 5. 部分失败（Review Focus 2）的明确策略

`PUT` 成功但 `POST /admin/images` 失败时，R2 里会留下**已上传但未登记**的对象。本批次的做法：

1. 登记接口把失败原因与 `url`（含 object key）写进 `console.error`，日志格式固定为
   `[admin-images] 登记失败 url=... reason=...`，便于用日志捞回孤儿；
2. 返回**可重试**的 5xx（而不是 4xx）：客户端可以对同一 `url` 重试登记，服务端允许重复登记同一 URL
   （不因为"URL 已存在"而拒绝 —— 重复登记只会多一行，管理页可以删掉；比留下孤儿好）；
3. 删除接口**不删 R2 对象**，所以"上传后没登记"的对象不会被任何接口自动清掉。清理工具
   （按 R2 前缀列出对象、减去库里已登记的 URL）不在 Task 1–4 范围内，记在后续批次。

---

## 验证记录（2026-10-07，Task 1–4 完成后实测）

单测（新增，`pnpm test:api`）：

```
$ node --import tsx --test tests/api/admin-api.test.ts
ℹ tests 22   ℹ pass 22   ℹ fail 0
```
覆盖：未登录四个端点全 401、文件名路径穿越 9 种形态、相册穿越、不存在的相册、
非图片 content type、正常签发的确定性 key 与响应、签发失败 500、登记时强制 `show/show_on_mainpage = 0`、
客户端塞 `preview_url/blurhash/show/del/id` 无效、非本存储 URL 被拒（防 SSRF）、登记失败 500、
列表分页与 DTO 映射（含 null/异构 Json）、删除 id 校验、`buildUploadKey` 与 web 原表达式逐字符一致。

curl 实测（本机 `next dev -p 3210` + 临时会话，会话与数据用完都清掉了）：

| 场景 | 结果 |
|---|---|
| 未登录（4 个端点） | 全部 `401` |
| **伪造 cookie**（中间件只看 cookie 在不在） | `401` —— 证明路由内的 `auth.api.getSession()` 真的在验签 |
| 路径穿越 `../../etc/passwd.jpg` | `400 {"code":400,"message":"invalid_filename"}` |
| 不存在的相册 `/nope` | `400 unknown_album` |
| `shell.php` | `400 invalid_filename` |
| 登记非本存储 URL | `400 url_not_in_storage` |
| 正常签发 | `200`，key=`images/daily/xfzfoeaulq99ij0wwfdvy8nn.jpg`（与 web 同一布局） |
| 用签发的 URL 真 PUT | `HTTP 200`，32013 字节上传成功 |
| 公开域名可访问原图 | `HTTP 200 image/jpeg 32013` |
| 登记 | `200`；**服务端把客户端乱报的 1x1 改成 1600x1000**，并生成预览图与 blurhash |
| 预览图 | `HTTP 200 image/webp 5614`（原图 32KB → 5.6KB） |
| 登记后在 web 公开 API `/api/public/v1/images?album=/daily` | **立刻可见**（缓存已预热的情况下也是立刻） |
| DB 行 | `show=0, show_on_mainpage=0, del=0, type=1, lat="", lon=""`，预览图/blurhash 都是服务端那份 |
| 删除 | `200 {"deleted":true}`；DB 里 `del` 0→1、相册关系被清除 |
| 删除后 | 管理列表立刻少一条；web 公开 API **立刻**看不到 |

⚠️ 一个踩到的坑（已修）：Next 16 的 `revalidateTag` 需要第二个参数，官方弃用提示说用 `'max'`。
**实测 `'max'` 这个 profile 不会让缓存立刻失效**（登记/删除后 web 最长要等 60s 的 `revalidate: 60` 窗口），
而 `revalidateTag(IMAGES_TAG, { expire: 0 })` 才是立刻生效（已实测：登记后立刻可见、删除后立刻消失），
且类型正确。既有三处 `revalidateTag(tag)` 单参数调用仍是老的（会打弃用警告），不在本次改动范围。

清理：验证用的 4 行测试数据已从库里物理删除（`images` 总数 71 → 67，残留 0）；
R2 上本次产生的 6 个对象（2 原图 + 4 预览图）已删除（用 S3 API HEAD 复核为 404；
公开域名仍返回 200 是 Cloudflare 边缘缓存尚未过期，不是对象还在）；
为 curl 临时造的 3 条会话已吊销（只剩真实客户端的会话）。

### 顺带发现的既有缺口（本次**没有**修，只记录）

`proxy.ts:5` 用的 `getSessionCookie()` 只判断 cookie **在不在**，不验签也不查库。
既有的写接口（`POST /api/v1/images/add`、`DELETE /api/v1/images/delete/:id`、
`PUT /api/v1/images/update*`、`/api/v1/settings` 等）**都只有这一层**，路由内不校验会话。
实测：带一个伪造的 `pic-impact.session_token=forged.signature` 打 `POST /api/v1/images/add`，
请求**穿过了中间件**（返回的是业务错误 500 "Image link cannot be empty"，而不是 401）；
同一个伪造 cookie 打本次新增的 `/api/v1/admin/uploads/sign` 则是 401（被路由内的
`auth.api.getSession()` 拦住）。

也就是说：**只要伪造一个 cookie 名，就能通过既有的写接口改数据库**。这是既有问题，
不在本批次范围（本次不改既有接口的行为），但它比本批次新增的任何东西都严重，
建议单独排一个修复：把会话校验收成一个共用的 Hono 中间件，所有写接口都挂上。

---

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
