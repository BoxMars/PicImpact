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
import { requireSession } from '~/hono/require-session'
import { HTTPException } from 'hono/http-exception'
import { revalidateTag } from 'next/cache'
import { IMAGES_TAG } from '~/server/db/query/images'
import { attachManagedImageMetadata } from '~/server/lib/managed-image'

const app = new Hono()

// 真正的会话校验（proxy.ts 那道门禁只判断 cookie 在不在，不能作为鉴权依据）
app.use('*', requireSession)

/**
 * 失效图片相关缓存（画廊列表 / 总数）。包 try/catch：失效失败不应让写操作失败。
 * 图片有新写入而不失效的话，画廊最长 60 秒看不到变化。
 */
function invalidateImages() {
  try {
    revalidateTag(IMAGES_TAG)
  } catch (e) {
    console.warn('[cache] revalidateTag(images) 失败：', e)
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
    // 服务端补齐 preview_url / width / height / blurhash，并规范化 EXIF 拍摄时间。
    // 实现见 server/lib/managed-image.ts —— 与 App 的登记接口共用同一份，避免两边漂移。
    await attachManagedImageMetadata(body)
    // 保存图片信息
    const res = await insertImage(body)
    invalidateImages()
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
    invalidateImages()
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.delete('/delete/:id', async (c) => {
  try {
    const { id } = c.req.param()
    await deleteImage(id)
    invalidateImages()
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
    invalidateImages()
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.put('/update-show', async (c) => {
  const image = await c.req.json()
  const data = await updateImageShow(image.id, image.show)
  invalidateImages()
  return c.json(data)
})

app.put('/update-Album', async (c) => {
  const image = await c.req.json()
  try {
    await updateImageAlbum(image.imageId, image.albumId)
    invalidateImages()
    return c.json({
      code: 200,
      message: 'Success'
    })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

export default app
