import 'server-only'
import {
  deleteBatchImage,
  deleteImage,
  insertImage,
  updateImage,
  updateImageShow,
  updateImageAlbum
} from '~/server/db/operate/images'
import { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { normalizeExifDateTime } from '~/lib/utils/exif-time'
import { fetchConfigsByKeys } from '~/server/db/query/configs'
import {
  R2_CONFIG_KEYS,
  S3_CONFIG_KEYS,
  ensureManagedPreviewUrl,
  resolveStorageTargets,
} from '~/server/lib/preview-storage'

const app = new Hono()

/**
 * 入库前由**服务端**生成受管缩略图并写回 `preview_url`，同时用原图的真实显示尺寸
 * 修正 `width`/`height`。
 *
 * 为什么要无条件重生：原缺陷是浏览器端 Compressor.js 的 `maxWidth` 被配置项
 * （`preview_max_width_limit_switch=1` 但 `preview_max_width_limit=0`）求值为
 * `undefined`，于是"只重编码、从不缩放"。客户端传来的 preview 即使形态上是
 * `/preview/xxx.webp` 也仍可能是 12MP 的全尺寸图，形态检查无法识别（见 spec R1.2）。
 *
 * 失败**不阻断入库** —— 存储瞬时故障不该让整次上传白做。失败会打日志，
 * 并可由 `pnpm migrate:regenerate-previews` 回填。
 */
async function attachManagedPreview(body: any): Promise<void> {
  if (!body?.url) return
  try {
    const configs = await fetchConfigsByKeys([...R2_CONFIG_KEYS, ...S3_CONFIG_KEYS])
    const targets = resolveStorageTargets(configs)
    const result = await ensureManagedPreviewUrl(body.url, targets)

    if (!result.ok) {
      console.warn(`[preview] 未能生成受管缩略图，入库继续：${result.reason}`)
      return
    }

    body.preview_url = result.previewUrl
    if (result.originalWidth > 0 && result.originalHeight > 0) {
      body.width = result.originalWidth
      body.height = result.originalHeight
    }
    const ratio = ((1 - result.previewBytes / result.originalBytes) * 100).toFixed(1)
    console.log(
      `[preview] ${result.originalBytes}B → ${result.previewBytes}B (−${ratio}%) ` +
        `缩略图 ${result.width}x${result.height}，原图显示尺寸 ${result.originalWidth}x${result.originalHeight}`,
    )
  } catch (e) {
    console.warn('[preview] 生成缩略图抛错，入库继续：', e)
  }
}

app.post('/add', async (c) => {
  const body = await c.req.json()
  if (!body) {
    throw new HTTPException(400, { message: 'Missing body' })
  }

  // 验证基本图片信息
  if (!body.url) {
    throw new HTTPException(500, { message: 'Image link cannot be empty' })
  }
  if (!body.height || body.height <= 0) {
    throw new HTTPException(500, { message: 'Image height cannot be empty and must be greater than 0' })
  }
  if (!body.width || body.width <= 0) {
    throw new HTTPException(500, { message: 'Image width cannot be empty and must be greater than 0' })
  }

  try {
    // 兼容并规范化 EXIF 拍摄时间
    if (body?.exif) {
      const normalizedCaptureTime = normalizeExifDateTime(
        body?.exif?.data_time || body?.exif?.date_time || ''
      )
      body.exif.data_time = normalizedCaptureTime
    }
    // 服务端生成缩略图（并修正宽高）
    await attachManagedPreview(body)
    // 保存图片信息
    const res = await insertImage(body)
    return Response.json({
      code: 200,
      data: res
    })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.delete('/batch-delete', async (c) => {
  try {
    const data = await c.req.json()
    await deleteBatchImage(data)
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.delete('/delete/:id', async (c) => {
  try {
    const { id } = c.req.param()
    await deleteImage(id)
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.put('/update', async (c) => {
  const image = await c.req.json()
  if (!image.url) {
    throw new HTTPException(500, { message: 'Image link cannot be empty' })
  }
  if (!image.height || image.height <= 0) {
    throw new HTTPException(500, { message: 'Image height cannot be empty and must be greater than 0' })
  }
  if (!image.width || image.width <= 0) {
    throw new HTTPException(500, { message: 'Image width cannot be empty and must be greater than 0' })
  }
  try {
    await updateImage(image)
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.put('/update-show', async (c) => {
  const image = await c.req.json()
  const data = await updateImageShow(image.id, image.show)
  return c.json(data)
})

app.put('/update-Album', async (c) => {
  const image = await c.req.json()
  try {
    await updateImageAlbum(image.imageId, image.albumId)
    return c.json({
      code: 200,
      message: 'Success'
    })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

export default app
