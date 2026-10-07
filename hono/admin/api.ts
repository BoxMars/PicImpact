import { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'

import {
  IMAGE_ID_PATTERN,
  SIGN_EXPIRES_IN_SECONDS,
  apiError,
  listQuerySchema,
  registerRequestSchema,
  signRequestSchema,
  toAdminImageSummary,
  type AdminImageSummary,
} from '~/server/lib/admin-api'
import { buildUploadKey, extensionOf, isKeyWithinFolder, isSafeAlbumValue, isUrlUnderPrefix } from '~/server/lib/upload-key'
import { createRequireSession } from '~/hono/require-session'

/**
 * 管理端 API 的路由**工厂**（`/api/v1/admin/*`）。
 *
 * ## 为什么是工厂 + 依赖注入
 * 这个文件里没有任何 `server-only` 的 import，数据库/存储/会话都从 `deps` 进来。
 * 这样"未登录被拒"、"路径穿越被拒"、"正常签发"、"正常登记"这几条**能在 `node --test` 下直接断言**，
 * 不必起 Next、连生产库、真的去签一个 R2 URL。
 * 真实依赖的装配在 `hono/admin/index.ts`（那个文件才 import server-only 与 Prisma）。
 *
 * 代价要说清楚：**这层装配本身（真实会话校验、真实签名、真实入库）不被单测覆盖**，
 * 只能靠 curl 打真接口来验。这是刻意的取舍 —— 单测不该碰生产库。
 */

export type AdminSession = {
  userId: string
  email: string
}

/** 登记入库的入参（字段名与服务端既有 `insertImage` / `ImageType` 对齐） */
export type RegisterImageInput = {
  albumValue: string
  url: string
  imageName: string
  title: string
  detail: string
  labels: string[]
  exif?: Record<string, unknown>
  lat: string
  lon: string
  width: number
  height: number
  type: number
  /** 显式写 0，不依赖数据库默认值（`images.show` 的默认是 1 = 隐藏） */
  show: 0
  /** 同上（`images.show_on_mainpage` 的默认也是 1） */
  showOnMainpage: 0
}

export type RegisteredImage = {
  id: string
  url: string
  previewUrl: string
  width: number
  height: number
  blurhash: string
  albumValue: string
  show: number
  showOnMainpage: number
}

export type StorageTargetInfo = {
  /** `configs.r2_storage_folder`，例如 `images` */
  folder: string
  /** `configs.r2_public_domain`（去掉结尾斜杠），例如 `https://felina-asset.boxz.dev` */
  publicPrefix: string
}

export interface AdminApiDeps {
  /** **真正**校验会话（不是只看 cookie 在不在）。未登录返回 null。 */
  getSession(headers: Headers): Promise<AdminSession | null>
  /** 当前存储目标（R2）。未配置时 folder/publicPrefix 为空串。 */
  storageTarget(): Promise<StorageTargetInfo>
  /** 相册是否存在且未删除 */
  albumExists(albumValue: string): Promise<boolean>
  /** 签发预签名 PUT URL（真实实现复用 server/lib/s3api.ts） */
  signPutUrl(input: { key: string; contentType: string; expiresInSeconds: number }): Promise<string>
  /** 登记入库，返回入库后的行（预览图/宽高/blurhash 已由服务端矫正） */
  registerImage(input: RegisterImageInput): Promise<RegisteredImage>
  /** 管理列表（复用 fetchServerImagesListByAlbum / fetchServerImagesPageTotalByAlbum） */
  listImages(input: { page: number; pageSize: number; album: string; show: number }): Promise<{ total: number; rows: Record<string, any>[] }>
  /** 软删除（复用 deleteImage：del = 1 + 删相册关系） */
  deleteImage(id: string): Promise<void>
  /** 生成对象名（注入是为了让测试能断言确定的 key） */
  newId(): string
  /** 失效图片缓存（复用 revalidateTag(IMAGES_TAG)） */
  invalidate(): void
}

export function createAdminApi(deps: AdminApiDeps): Hono {
  const app = new Hono()

  // 未预期的异常也要返回 JSON（客户端只认 json）。HTTPException 自带 res，原样返回。
  app.onError((err, c) => {
    if (err instanceof HTTPException) return err.getResponse()
    console.error('[admin-api] 未预期错误：', err)
    return c.json({ code: 500, message: 'internal error' }, 500)
  })

  // 会话校验用**全站唯一的那份实现**（hono/require-session.ts，与 legacy 写接口共用）。
  // 这里把 deps 的查询函数传进去，是为了让单测能注入替身而不碰数据库。
  app.use('*', createRequireSession((headers) => deps.getSession(headers)))

  async function readJson(c: { req: { json: () => Promise<unknown> } }): Promise<unknown> {
    try {
      return await c.req.json()
    } catch {
      throw apiError(400, 'invalid_json')
    }
  }

  /** 相册必须存在：否则等于允许把对象签进任意前缀 */
  async function requireAlbum(albumValue: string): Promise<void> {
    if (!isSafeAlbumValue(albumValue)) throw apiError(400, 'invalid_album')
    if (!(await deps.albumExists(albumValue))) throw apiError(400, 'unknown_album')
  }

  // -------------------------------------------------------------------------
  // 1. 预签名上传
  // -------------------------------------------------------------------------
  app.post('/uploads/sign', async (c) => {
    const parsed = signRequestSchema.safeParse(await readJson(c))
    if (!parsed.success) throw apiError(400, 'invalid_request')
    const { filename, contentType, albumValue } = parsed.data

    if (!/^(image|video)\//.test(contentType)) throw apiError(400, 'invalid_content_type')
    const extension = extensionOf(filename)
    if (!extension) throw apiError(400, 'invalid_filename')
    await requireAlbum(albumValue)

    const target = await deps.storageTarget()
    if (!target.folder || !target.publicPrefix) throw apiError(500, 'storage_not_configured')

    const key = buildUploadKey(target.folder, albumValue, `${deps.newId()}.${extension}`)
    // 兜底断言：签发之前确认 key 没有逃出存储前缀（正常构造下必然成立）
    if (!isKeyWithinFolder(key, target.folder)) throw apiError(400, 'invalid_key')

    let uploadUrl: string
    try {
      uploadUrl = await deps.signPutUrl({ key, contentType, expiresInSeconds: SIGN_EXPIRES_IN_SECONDS })
    } catch (error) {
      console.error(`[admin-api] 签发预签名 URL 失败 key=${key}：`, error)
      throw apiError(500, 'sign_failed')
    }

    return c.json({
      code: 200,
      data: {
        key,
        uploadUrl,
        publicUrl: `${target.publicPrefix}/${key}`,
        contentType,
        expiresInSeconds: SIGN_EXPIRES_IN_SECONDS,
      },
    })
  })

  // -------------------------------------------------------------------------
  // 2. 登记元数据
  // -------------------------------------------------------------------------
  app.post('/images', async (c) => {
    const parsed = registerRequestSchema.safeParse(await readJson(c))
    if (!parsed.success) throw apiError(400, 'invalid_request')
    const body = parsed.data

    const target = await deps.storageTarget()
    // 只允许登记自家存储上的对象：预览图那一步会真的去 fetch 这个 URL（防 SSRF）
    if (!isUrlUnderPrefix(body.url, target.publicPrefix)) throw apiError(400, 'url_not_in_storage')
    await requireAlbum(body.albumValue)

    let saved: RegisteredImage
    try {
      saved = await deps.registerImage({
        albumValue: body.albumValue,
        url: body.url,
        imageName: body.imageName ?? '',
        title: body.title ?? '',
        detail: body.detail ?? '',
        labels: body.labels ?? [],
        exif: body.exif,
        // 缺省写空串：不能让 server/db/operate/images.ts 里的 String(image.lat) 变成 "undefined"
        lat: body.lat ?? '',
        lon: body.lon ?? '',
        width: body.width ?? 0,
        height: body.height ?? 0,
        type: body.type ?? 1,
        show: 0,
        showOnMainpage: 0,
      })
    } catch (error) {
      // 孤儿对象策略（Review Focus 2）：PUT 已成功、登记失败时 R2 里会留下没登记的对象。
      // 这里把 url 与原因打成固定格式的日志，便于事后捞回；返回 5xx 让客户端可以重试登记。
      console.error(
        `[admin-images] 登记失败 url=${body.url} reason=${error instanceof Error ? error.message : String(error)}`,
      )
      throw apiError(500, 'register_failed')
    }

    deps.invalidate()
    return c.json({ code: 200, data: saved })
  })

  // -------------------------------------------------------------------------
  // 3. 管理列表
  // -------------------------------------------------------------------------
  app.get('/images', async (c) => {
    const parsed = listQuerySchema.safeParse(c.req.query())
    if (!parsed.success) throw apiError(400, 'invalid_request')
    const { page, pageSize, album, show } = parsed.data

    const { total, rows } = await deps.listImages({ page, pageSize, album, show })
    return c.json({
      code: 200,
      data: {
        page,
        pageSize,
        total,
        hasMore: page * pageSize < total,
        items: rows.map(toAdminImageSummary),
      },
    })
  })

  // -------------------------------------------------------------------------
  // 4. 软删除
  // -------------------------------------------------------------------------
  app.delete('/images/:id', async (c) => {
    const id = c.req.param('id') ?? ''
    if (!IMAGE_ID_PATTERN.test(id)) throw apiError(400, 'invalid_id')

    await deps.deleteImage(id)
    deps.invalidate()
    return c.json({ code: 200, data: { id, deleted: true } })
  })

  return app
}

export type { AdminImageSummary }
