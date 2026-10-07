import 'server-only'

import { createId } from '@paralleldrive/cuid2'
import { revalidateTag } from 'next/cache'

import { auth } from '~/server/auth'
import { deleteImage, insertImage } from '~/server/db/operate/images'
import { fetchConfigsByKeys } from '~/server/db/query/configs'
import {
  IMAGES_TAG,
  fetchServerImagesListByAlbum,
  fetchServerImagesPageTotalByAlbum,
} from '~/server/db/query/images'
import { db } from '~/server/lib/db'
import { attachManagedImageMetadata } from '~/server/lib/managed-image'
import { R2_CONFIG_KEYS } from '~/server/lib/preview-storage'
import { getR2Client } from '~/server/lib/r2'
import { generatePresignedUrl } from '~/server/lib/s3api'
import type { Config } from '~/types'

import { createAdminApi } from './api'

/**
 * `/api/v1/admin/*` 的真实依赖装配。
 *
 * 路由逻辑在 `./api.ts`（纯工厂，可单测）；**这个文件才 import server-only 与 Prisma**，
 * 所以它不会被单测加载 —— 真实会话校验、真实签名、真实入库只由 curl 打真接口来验。
 */

const configValue = (configs: Config[], key: string): string =>
  configs.find((item) => item.config_key === key)?.config_value ?? ''

export default createAdminApi({
  async getSession(headers) {
    // ⚠️ 这里才是真正的会话校验：proxy.ts 用的 getSessionCookie() 只判断 cookie 在不在、不验签。
    const session = await auth.api.getSession({ headers })
    if (!session?.user) return null
    return { userId: session.user.id, email: session.user.email }
  },

  async storageTarget() {
    const configs = await fetchConfigsByKeys(R2_CONFIG_KEYS)
    return {
      folder: configValue(configs, 'r2_storage_folder'),
      // 去掉结尾斜杠：后面是 `${prefix}/${key}` 拼法
      publicPrefix: configValue(configs, 'r2_public_domain').replace(/\/+$/, ''),
    }
  },

  async albumExists(albumValue) {
    const album = await db.albums.findFirst({
      where: { album_value: albumValue, del: 0 },
      select: { id: true },
    })
    return !!album
  },

  async signPutUrl({ key, contentType, expiresInSeconds }) {
    const configs = await fetchConfigsByKeys(R2_CONFIG_KEYS)
    const bucket = configValue(configs, 'r2_bucket')
    if (!bucket) throw new Error('R2 bucket 未配置')
    // 复用既有实现：客户端来自 server/lib/r2.ts，签名来自 server/lib/s3api.ts
    const client = getR2Client(configs)
    return generatePresignedUrl(client, bucket, key, contentType, 'put', expiresInSeconds)
  },

  async registerImage(input) {
    // 字段名对齐 ImageType / insertImage（snake_case 那一侧）
    const image: Record<string, any> = {
      album: input.albumValue,
      url: input.url,
      image_name: input.imageName,
      title: input.title,
      detail: input.detail,
      labels: input.labels,
      exif: input.exif,
      lat: input.lat,
      lon: input.lon,
      width: input.width,
      height: input.height,
      type: input.type,
      show: input.show,
      show_on_mainpage: input.showOnMainpage,
    }

    // 服务端补齐 preview_url / width / height / blurhash（与 web 上传共用同一份实现）
    await attachManagedImageMetadata(image)

    const row = await insertImage(image as any)
    return {
      id: row.id,
      url: row.url ?? input.url,
      previewUrl: row.preview_url || input.url,
      width: row.width,
      height: row.height,
      blurhash: row.blurhash ?? '',
      albumValue: input.albumValue,
      show: row.show,
      showOnMainpage: row.show_on_mainpage,
    }
  },

  async listImages({ page, pageSize, album, show }) {
    const [rows, total] = await Promise.all([
      fetchServerImagesListByAlbum(page, album, show, undefined, undefined, pageSize),
      fetchServerImagesPageTotalByAlbum(album, show),
    ])
    return { total, rows: rows as unknown as Record<string, any>[] }
  },

  async deleteImage(id) {
    await deleteImage(id)
  },

  newId() {
    // 对象名由服务端生成：客户端只能决定扩展名（见 server/lib/upload-key.ts）
    return createId()
  },

  invalidate() {
    try {
      revalidateTag(IMAGES_TAG, { expire: 0 })
    } catch (e) {
      console.warn('[cache] revalidateTag(images) 失败：', e)
    }
  },
})
