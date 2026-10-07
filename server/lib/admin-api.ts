import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'

/**
 * 管理接口（`/api/v1/admin/*`）的请求校验与 DTO 映射。
 *
 * 与 `server/lib/upload-key.ts` 一样，本模块**不 import 任何 `server-only` 的东西** ——
 * 校验规则与出参形状要能在 `node --test` 下直接断言，不必起 Next、连数据库。
 * 契约（字段出处）见 `docs/superpowers/plans/2026-10-07-ios-image-admin.md` 的 Task 1 产出。
 */

/** 单次上传的软上限（200MB）。注意 PUT 预签名 URL 无法在服务端强制大小，见契约里的说明。 */
export const MAX_UPLOAD_BYTES = 200 * 1024 * 1024

/** 预签名 URL 有效期（秒）。既有 `generatePresignedUrl` 默认 3600，写接口刻意取更短。 */
export const SIGN_EXPIRES_IN_SECONDS = 900

/** 管理列表默认每页条数（与 App 的无限滚动配合；上限 60 防止一次拉爆）。 */
export const DEFAULT_PAGE_SIZE = 24
export const MAX_PAGE_SIZE = 60

/**
 * 统一的错误响应：`{"code": <status>, "message": "..."}`，HTTP 状态码一致。
 *
 * 用带 `res` 的 `HTTPException` 而不是只给 message：`hono/index.ts` 的 onError 会把
 * `err.getResponse()` 原样返回，所以无论错误最终被哪一层 onError 接住，客户端拿到的都是这个 JSON。
 */
export function apiError(status: 400 | 401 | 403 | 404 | 500, message: string): HTTPException {
  return new HTTPException(status, {
    res: Response.json({ code: status, message }, { status }),
  })
}

// ---------------------------------------------------------------------------
// 请求体
// ---------------------------------------------------------------------------

export const signRequestSchema = z.object({
  /** 只用来取扩展名；对象名由服务端生成 */
  filename: z.string().min(1).max(200),
  contentType: z.string().min(1).max(100),
  /** 形如 `/daily`，必须是库里存在且未删除的相册 */
  albumValue: z.string().min(1).max(200),
  /** 可选：仅用于拒绝明显超限的上传（软限制） */
  size: z.number().int().positive().max(MAX_UPLOAD_BYTES).optional(),
})

export type SignRequest = z.infer<typeof signRequestSchema>

/**
 * 登记请求。
 *
 * ⚠️ 刻意**不包含** `preview_url` / `blurhash` / `show` / `show_on_mainpage` / `del` / `sort` / `id`：
 * 前两个由服务端从原图算（Review Focus 4 的裁决），中间几个是本站的内部状态，客户端无权设置。
 * `z.object()` 默认丢弃未声明字段，所以客户端塞了也进不来。
 */
export const registerRequestSchema = z.object({
  albumValue: z.string().min(1).max(200),
  url: z.url().max(2000),
  imageName: z.string().max(500).optional(),
  title: z.string().max(200).optional(),
  detail: z.string().max(5000).optional(),
  labels: z.array(z.string().max(100)).max(100).optional(),
  exif: z.record(z.string(), z.unknown()).optional(),
  lat: z.string().max(100).optional(),
  lon: z.string().max(100).optional(),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
  /** 1 = 普通图片，2 = livephoto（见 prisma/schema.prisma 的注释） */
  type: z.union([z.literal(1), z.literal(2)]).optional(),
})

export type RegisterRequest = z.infer<typeof registerRequestSchema>

/** 列表查询参数（URL query 里全是字符串，用 coerce 转成数字） */
export const listQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  pageSize: z.coerce.number().int().min(1).max(MAX_PAGE_SIZE).default(DEFAULT_PAGE_SIZE),
  album: z.string().max(200).default(''),
  /** -1 = 全部；0 = 已公开；1 = 未公开（语义见 server/db/query/images.ts:30） */
  show: z.coerce.number().int().min(-1).max(1).default(-1),
})

export type ListQuery = z.infer<typeof listQuerySchema>

/** 图片 id 的形状：`Images.id` 是 cuid2 的 `VarChar(50)` */
export const IMAGE_ID_PATTERN = /^[A-Za-z0-9_-]{1,50}$/

// ---------------------------------------------------------------------------
// 出参
// ---------------------------------------------------------------------------

/** 管理列表里的一条（只含管理页用得上的字段，不复用公开接口的 DTO） */
export type AdminImageSummary = {
  id: string
  url: string
  previewUrl: string
  title: string
  detail: string
  width: number
  height: number
  show: number
  showOnMainpage: number
  labels: string[]
  createdAt: string | null
  albumValue: string
  albumName: string
  exif: { model: string; lensModel: string; dataTime: string }
}

const asString = (value: unknown): string => (typeof value === 'string' ? value : value == null ? '' : String(value))
const asNumber = (value: unknown): number => {
  const num = Number(value)
  return Number.isFinite(num) ? num : 0
}

/**
 * 把 `fetchServerImagesListByAlbum()` 出来的原始 SQL 行（snake_case）映射成管理页 DTO。
 *
 * 映射写成纯函数是为了能单测：数据库返回的 `labels` 是 Json（可能是 null、可能是数组），
 * `exif` 同样，`preview_url` 还可能为空 —— 这些边界直接在测试里钉住，比在真机上试便宜得多。
 */
export function toAdminImageSummary(row: Record<string, any>): AdminImageSummary {
  const url = asString(row?.url)
  const exif = (row?.exif ?? {}) as Record<string, unknown>
  return {
    id: asString(row?.id),
    url,
    // 预览图缺失时退回原图：管理页至少能看到东西（与 web 的 list-image.tsx:13 同一策略）
    previewUrl: asString(row?.preview_url) || url,
    title: asString(row?.title),
    detail: asString(row?.detail),
    width: asNumber(row?.width),
    height: asNumber(row?.height),
    show: asNumber(row?.show),
    showOnMainpage: asNumber(row?.show_on_mainpage),
    labels: Array.isArray(row?.labels) ? row.labels.filter((item: unknown) => typeof item === 'string') : [],
    createdAt: row?.created_at ? new Date(row.created_at).toISOString() : null,
    albumValue: asString(row?.album_value),
    albumName: asString(row?.album_name),
    exif: {
      model: asString(exif.model),
      lensModel: asString(exif.lens_model),
      dataTime: asString(exif.data_time),
    },
  }
}
