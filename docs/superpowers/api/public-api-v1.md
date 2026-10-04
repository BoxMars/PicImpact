# 公开 API v1 —— 契约与版本政策

- **状态**：已发布（iOS App 依赖）
- **基址**：`https://felina.boxz.dev/api/public/v1`
- **鉴权**：无（`proxy.ts` 的 matcher 已排除 `api/public`，这些接口天然不需要会话）
- **缓存**：`Cache-Control: public, s-maxage=60, stale-while-revalidate=300`，可被 Cloudflare 边缘缓存
- **契约实现点**：`hono/public-api/v1/serialize.ts`
- **自动化校验**：`pnpm api:verify-contract`

---

## 0. 为什么需要这份文档

App Store 里的旧版 App **不可能被强制升级**。用户可能永远停在某个版本上。
因此后端每一次改动都必须回答一个问题：**"这会不会让还在用旧版的用户打不开？"**

这份文档把答案制度化：**在 v1 里只允许"加字段"，任何破坏性变更都必须新开一个版本。**

---

## 1. 版本政策（三条硬规则）

### 规则 1：URL 版本前缀，版本一旦发布永不删除

```
/api/public/v1/...     ← 已发布
/api/public/v2/...     ← 将来需要破坏性变更时新增
```

`hono/public-api/shared.ts` 的 `PUBLIC_API_VERSIONS` 是版本登记表。
**删掉一个版本 = 让那部分用户直接不可用**，不允许。

### 规则 2：版本内只能"做加法"

| 变更 | 允许？ |
|---|---|
| 新增字段 | ✅ 允许（旧 App 会忽略未知字段） |
| 新增可选查询参数 | ✅ 允许 |
| 新增端点 | ✅ 允许 |
| 新增 `features` 能力开关 | ✅ 允许 |
| **删除字段** | ❌ 必须开 v2 |
| **重命名字段** | ❌ 必须开 v2 |
| **改变字段类型**（如 number → string） | ❌ 必须开 v2 |
| **改变字段语义**（如 `type` 从 1/2 改成字符串） | ❌ 必须开 v2 |
| **改变错误码 / 状态码含义** | ❌ 必须开 v2 |

### 规则 3：契约由一个文件冻结

**`hono/public-api/v1/serialize.ts` 是唯一的契约实现点。**

数据库与 Prisma 模型可以随便演进 —— 只要在那份文件里把值映射回 v1 的形状。
例如将来把列 `preview_url` 改名为 `thumb_url`，就在 `toImageDTOv1` 里写
`previewUrl: image.thumb_url`，**v1 对外输出的形状不变，旧 App 无感**。

> 这正是"Web 端只增加 API、不动其它"能成立的前提：契约与存储解耦了。

---

## 2. 端点参考

### 2.1 `GET /config` —— 客户端**必须最先调用**

它同时承担「能力协商」职责：App 依据 `features` 决定显示哪些功能，
而不是靠硬编码版本号去猜。

```json
{
  "code": 200,
  "message": "ok",
  "data": {
    "apiVersion": "v1",
    "pageSize": 24,
    "site": {
      "title": "大福映画 Felina Gallery",
      "author": "Felina, Juliana and Box",
      "logoUrl": "",
      "faviconUrl": "https://felina-asset.boxz.dev/assert/ICON-Felina.jpg",
      "indexStyle": "1"
    },
    "features": {
      "download": true,
      "origin": true,
      "toneAnalysis": true,
      "livePhoto": true,
      "map": true
    }
  }
}
```

**⚠️ 布尔语义**：`config_value` 在数据库里存的是字符串 `"true"` / `"false"`，
**不是** `"1"` / `"0"`（Web 端判的是 `config_value.toString() === 'true'`，见
`components/gallery/simple/gallery-image.tsx:274`）。而 `indexStyle` 才是 `'0' | '1' | '2'` 枚举。
这两者曾经被我混为一谈（写成 `=== '1'`），导致生产已开启下载却对外报 `download: false`。
`pnpm api:verify-contract` 现在会断言这一点。

### 2.2 `GET /albums`

```json
{ "code": 200, "message": "ok", "data": [
  { "id": "…", "name": "日常", "value": "/daily", "detail": null, "theme": "0", "license": null }
] }
```

服务端已过滤 `show = 0` 且 `del = 0`，并排除首页用的 `/`。
`theme` 字段保留但 **iOS 刻意忽略**（只做 ACNH 岛屿卡，见设计文档 §2.2）。

### 2.3 `GET /tags`

```json
{ "code": 200, "message": "ok", "data": ["日常", "街拍"] }
```

### 2.4 `GET /filters?album=/daily`

```json
{ "code": 200, "message": "ok", "data": { "cameras": ["ILCE-7M4"], "lenses": ["FE 35mm F1.8"] } }
```

`album` 可选；不传返回全部。

### 2.5 `GET /images` —— 列表（核心）

| 参数 | 说明 |
|---|---|
| `page` | 页码，≥1，默认 1。非法值回退为 1（不报错） |
| `album` | 相册 value，形如 `/daily`。**默认 `/`，即首页**（所有 `show_on_mainpage = 0` 的图） |
| `tag` | 标签。**优先级高于 `album`**（显式传 tag 时忽略 album） |
| `camera` / `lens` | 仅 album 模式生效，与 Web 端行为一致 |

**没有 `size` 参数** —— 服务端查询里 `LIMIT` 写死为 24（`server/db/query/images.ts` 的 `DEFAULT_SIZE`），
提供却不能生效比不提供更糟。页大小请从响应的 `pageSize` 读取，**不要硬编码**。

```json
{ "code": 200, "message": "ok", "data": {
  "list": [ /* ImageDTO[] */ ],
  "page": 1,
  "pageSize": 24,
  "pageTotal": 2,
  "hasMore": true,
  "album": "/daily"
} }
```

**注意**：`pageTotal` 是总**页数**，不是总条数（服务端就是这么算的：`ceil(total / 24)`）。
判断还有没有下一页请用 `hasMore`。

### 2.6 `GET /images/:id` —— 单图

用途：深链接（App 被 URL 唤起直接打开某张图）时无需先拉列表。
只返回公开图片；不存在或非公开时返回 `404` 且 `data: null`。

---

## 3. `ImageDTO` 字段表（v1 冻结）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | |
| `imageName` | string | 原始文件名，客户端保存到相册时用作文件名 |
| `url` | string | 原图 URL |
| `previewUrl` | string | 800px 缩略图 URL。**列表一律用它** |
| `videoUrl` | string | Live Photo 的视频 URL |
| `blurhash` | string | 占位模糊图（需客户端解码） |
| `width` / `height` | number | 原图像素尺寸 |
| `title` / `detail` | string | |
| `type` | number | **1 = 普通图片，2 = Live Photo** |
| `labels` | string[] | 已归一化：库里是 `json`，可能是 `null` 或脏数据，统一成 `string[]` |
| `lon` / `lat` | string | **保持字符串**（数据库列类型就是 String，避免浮点精度差异与空值解码失败） |
| `exif` | object \| null | **原样透传，不做字段白名单** —— 服务端新增 EXIF 字段无需发新版；客户端必须忽略未知字段 |
| `albumLicense` | string \| null | 下载/分享提示文案会用到（见 `gallery-image.tsx`） |
| `createdAt` | string \| null | ISO 8601（UTC） |

### 客户端四条兼容要求

1. **忽略未知字段**（服务端会一直加字段）
2. **不要硬编码 `pageSize`**
3. **不要假设 `labels` 一定非空**，`exif` 可能为 `null`
4. 先读 `/config` 的 `features`，再决定显示哪些功能

---

## 4. 怎么做破坏性变更（正确流程）

```
1. 复制 hono/public-api/v1/ → hono/public-api/v2/
2. 在 hono/public-api/index.ts 里加一行 app.route('/v2', v2)
3. 在 shared.ts 的 PUBLIC_API_VERSIONS 里追加 'v2'
4. 在 v2 里做你要的破坏性改动；v1 保持不动
5. 复制 docs/superpowers/api/fixtures/v1-contract.json 为 v2-contract.json 并更新校验脚本
6. 通知客户端升级（不要指望用户会升）
```

**弃用流程**（要下线某个版本时）：

1. 先在 `apiHeaders()` 里传 `{ deprecated: true }` → 响应带 `X-API-Deprecated: true`
2. 观察一段时间（`X-App-Version` 上报可用来统计还在用旧版的用户比例）
3. 再设 `Sunset` 头给出停止服务时间
4. **才**考虑移除

---

## 5. 自动化守护

```bash
pnpm api:verify-contract
```

它做三件事：

1. 用样本数据跑 v1 的序列化器，逐键比对字段集合与**运行期类型**
2. 递归校验 `config.site` / `config.features` 的嵌套键（那里的键被改名会让 App 静默失效）
3. 断言 config 的布尔语义（`'true'` 而非 `'1'`）与 `indexStyle` 映射

**失败时的意思**：你做了一个会打断旧版 App 的改动。要么改回去，要么按 §4 开 v2。

> 反向验证过：故意把 `previewUrl` 改名 → 报「缺少必需字段」（exit 1）；
> 故意把 `width` 改成 string → 报「类型变了」（exit 1）。

**建议接入 CI**：在 `.github/workflows/` 里加一步 `pnpm api:verify-contract`，让破坏性变更在 PR 阶段就被拦下。

---

## 6. v1 变更日志

| 日期 | 变更 | 类型 |
|---|---|---|
| 2026-10-04 | v1 首次发布：`/config` `/albums` `/tags` `/filters` `/images` `/images/:id` | 新增 |
