import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3'

import type { Config } from '~/types'
import { buildPreviewKey, generateThumbnail, readDisplaySize } from '~/server/lib/thumbnail'
import { encodeThumbHash } from '~/lib/utils/blurhash-server'

/**
 * 缩略图的存储侧PUT 与 URL↔key 映射。
 *
 * 供两处复用：
 * - `hono/images.ts` 的入库流程（新上传的图片自动获得受管缩略图）
 * - `scripts/migrate/regenerate-previews.ts` 的历史数据迁移
 *
 * 故意**不**引入 `server-only`：迁移脚本在纯 Node（tsx）下运行，引入会让它抛错。
 * 客户端保护由依赖本身提供（sharp / @aws-sdk 无法在浏览器打包）。
 */

export type StorageTarget = {
  kind: 'r2' | 's3'
  bucket: string
  /** 公开访问前缀（不带结尾斜杠），用于把公开 URL 反推为 object key */
  publicPrefix: string
  client: S3Client
}

export const R2_CONFIG_KEYS = [
  'r2_accesskey_id',
  'r2_accesskey_secret',
  'r2_account_id',
  'r2_bucket',
  'r2_storage_folder',
  'r2_public_domain',
]

export const S3_CONFIG_KEYS = [
  'accesskey_id',
  'accesskey_secret',
  'region',
  'endpoint',
  'bucket',
  'storage_folder',
  'force_path_style',
  's3_cdn',
  's3_cdn_url',
]

const get = (configs: Config[], key: string) =>
  configs.find((c) => c.config_key === key)?.config_value ?? ''

const stripTrailingSlash = (s: string) => s.replace(/\/+$/, '')

/**
 * 解析出所有可用的存储目标。调用方按 URL 前缀选择匹配的那一个。
 * 配置不全的后端会被跳过（例如未启用 S3 时 `accesskey_id` 为空）。
 */
export function resolveStorageTargets(configs: Config[]): StorageTarget[] {
  const targets: StorageTarget[] = []

  const r2Account = get(configs, 'r2_account_id')
  const r2Bucket = get(configs, 'r2_bucket')
  const r2Domain = stripTrailingSlash(get(configs, 'r2_public_domain'))
  const r2KeyId = get(configs, 'r2_accesskey_id')
  const r2Secret = get(configs, 'r2_accesskey_secret')
  if (r2Account && r2Bucket && r2Domain && r2KeyId && r2Secret) {
    targets.push({
      kind: 'r2',
      bucket: r2Bucket,
      publicPrefix: r2Domain,
      client: new S3Client({
        region: 'auto',
        endpoint: `https://${r2Account}.r2.cloudflarestorage.com`,
        credentials: { accessKeyId: r2KeyId, secretAccessKey: r2Secret },
      }),
    })
  }

  const s3KeyId = get(configs, 'accesskey_id')
  const s3Secret = get(configs, 'accesskey_secret')
  const s3Bucket = get(configs, 'bucket')
  const s3Endpoint = get(configs, 'endpoint')
  const s3Cdn = get(configs, 's3_cdn')
  const s3CdnUrl = stripTrailingSlash(get(configs, 's3_cdn_url'))
  if (s3KeyId && s3Secret && s3Bucket && s3Endpoint) {
    const host = s3Endpoint.includes('https://') ? s3Endpoint.split('//')[1] : s3Endpoint
    const forcePathStyle = get(configs, 'force_path_style') === 'true'
    const publicPrefix =
      s3Cdn === 'true' && s3CdnUrl
        ? s3CdnUrl
        : forcePathStyle
          ? `https://${host}/${s3Bucket}`
          : `https://${s3Bucket}.${host}`
    targets.push({
      kind: 's3',
      bucket: s3Bucket,
      publicPrefix,
      client: new S3Client({
        region: get(configs, 'region') || 'auto',
        endpoint: s3Endpoint.includes('https://') ? s3Endpoint : `https://${s3Endpoint}`,
        credentials: { accessKeyId: s3KeyId, secretAccessKey: s3Secret },
        forcePathStyle,
      }),
    })
  }

  return targets
}

export function pickTargetForUrl(targets: StorageTarget[], url: string): StorageTarget | null {
  return targets.find((t) => url.startsWith(`${t.publicPrefix}/`)) ?? null
}

export function urlToKey(url: string, target: StorageTarget): string {
  return url.slice(target.publicPrefix.length + 1)
}

export type EnsurePreviewResult =
  | {
      ok: true
      previewUrl: string
      /** 缩略图尺寸 */
      width: number
      height: number
      /** 原图**显示**尺寸（已应用 EXIF 方向），供调用方修正 images.width/height */
      originalWidth: number
      originalHeight: number
      originalBytes: number
      previewBytes: number
      /**
       * 原图的 ThumbHash（base64），写进 `images.blurhash`。
       *
       * 由服务端在**同一次下载**里算出来（见 `lib/utils/blurhash-server.ts` 的注释）：
       * 客户端不再需要自己实现 ThumbHash，web 与 App 的占位图也就必然一致。
       */
      blurhash: string
    }
  | { ok: false; reason: string }

/**
 * 由原图 URL 生成受管缩略图并上传，返回新的 `preview_url`（顺带返回宽高与 ThumbHash）。
 *
 * 不做任何"已存在就跳过"的判断：原缺陷的表现正是"形态合格但像素未缩放"，
 * 形态检查识别不出来（见 spec R1.2）。
 */
export async function ensureManagedPreviewUrl(
  originalUrl: string,
  targets: StorageTarget[],
): Promise<EnsurePreviewResult> {
  const target = pickTargetForUrl(targets, originalUrl)
  if (!target) {
    return { ok: false, reason: `原图 URL 不属于任何已配置的存储后端：${originalUrl.slice(0, 80)}` }
  }

  const res = await fetch(originalUrl)
  if (!res.ok) {
    return { ok: false, reason: `下载原图失败 HTTP ${res.status}` }
  }
  const original = Buffer.from(await res.arrayBuffer())
  // ThumbHash 失败不该拖垮缩略图（缩略图才是列表能不能用的关键），所以单独兜住
  const blurhashPromise = encodeThumbHash(original).catch((e) => {
    console.warn('[blurhash] 生成 ThumbHash 失败，降级为空：', e)
    return ''
  })
  const [thumb, display, blurhash] = await Promise.all([
    generateThumbnail(original),
    readDisplaySize(original),
    blurhashPromise,
  ])

  const { createId } = await import('@paralleldrive/cuid2')
  const previewKey = buildPreviewKey(urlToKey(originalUrl, target), createId())

  await target.client.send(
    new PutObjectCommand({
      Bucket: target.bucket,
      Key: previewKey,
      Body: thumb.buffer,
      ContentType: thumb.contentType,
      // 文件名是内容哈希（cuid），对象不可变 → 长 TTL 供边缘与浏览器长期缓存
      CacheControl: 'public, max-age=31536000, immutable',
    }),
  )

  return {
    ok: true,
    previewUrl: `${target.publicPrefix}/${previewKey}`,
    width: thumb.width,
    height: thumb.height,
    originalWidth: display.width,
    originalHeight: display.height,
    originalBytes: original.length,
    previewBytes: thumb.buffer.length,
    blurhash,
  }
}
