import 'server-only'

import { fetchConfigsByKeys } from '~/server/db/query/configs'
import type { Config } from '~/types'
import { Hono } from 'hono'
import { requireSession } from '~/hono/require-session'
import { HTTPException } from 'hono/http-exception'
import { updateOpenListConfig, updateCustomInfo, updateR2Config, updateS3Config, updatePushConfig } from '~/server/db/operate/configs'
import { revalidateTag } from 'next/cache'
import { CONFIGS_TAG } from '~/server/db/query/configs'

const app = new Hono()

/** 推送配置的键与默认值。旧库没跑过 seed（createMany 带 skipDuplicates，只对新库生效），行可能是缺的 */
const PUSH_CONFIG_DEFAULTS: Record<string, string> = {
  push_enabled: 'false',
  push_cooldown_seconds: '120',
}

/** 冷却秒数上限：再大也没有意义，还能挡住误填的巨型数字 */
const PUSH_COOLDOWN_SECONDS_MAX = 3600

// 真正的会话校验（proxy.ts 那道门禁只判断 cookie 在不在，不能作为鉴权依据）
app.use('*', requireSession)

/**
 * 失效配置缓存。包 try/catch：缓存失效失败不应让管理端的保存操作失败
 * （`revalidateTag` 要求处于 Server Action / Route Handler 的请求上下文中）。
 */
function invalidateConfigs() {
  try {
    revalidateTag(CONFIGS_TAG)
  } catch (e) {
    console.warn('[cache] revalidateTag(configs) 失败：', e)
  }
}

/**
 * 立即失效配置缓存（`{ expire: 0 }` profile）。
 *
 * 为什么不能用上面那个 `invalidateConfigs()`：`revalidateTag(tag)` 走的是"下次请求再验证"，
 * 在 `unstable_cache` 上实测读完仍是旧值，管理端要等最长 300 秒才看到效果；
 * `{ expire: 0 }` 才会立刻把缓存标记为过期（同 `hono/admin/index.ts` 对 IMAGES_TAG 的处理）。
 * 推送开关必须"改完立刻生效"，所以这里单独走一条。
 */
function invalidateConfigsImmediately() {
  try {
    revalidateTag(CONFIGS_TAG, { expire: 0 })
  } catch (e) {
    console.warn('[cache] revalidateTag(configs) 失败：', e)
  }
}

app.get('/get-custom-info', async (c) => {
  try {
    const data = await fetchConfigsByKeys([
      'custom_title',
      'custom_favicon_url',
      'custom_author',
      'rss_feed_id',
      'rss_user_id',
      'custom_index_style',
      'custom_index_download_enable',
      'preview_max_width_limit',
      'preview_max_width_limit_switch',
      'preview_quality',
      'umami_host',
      'umami_analytics',
      'max_upload_files',
      'custom_index_origin_enable',
      'admin_images_per_page'
    ])
    return c.json(data)
  } catch (error) {
    console.error('Error fetching custom info:', error)
    throw new HTTPException(500, { message: 'Failed to fetch custom info', cause: error })
  }
})

app.get('/r2-info', async (c) => {
  const data = await fetchConfigsByKeys([
    'r2_accesskey_id',
    'r2_accesskey_secret',
    'r2_account_id',
    'r2_bucket',
    'r2_storage_folder',
    'r2_public_domain',
    'r2_direct_download'
  ])
  return c.json(data)
})

app.get('/get-push-info', async (c) => {
  const data = await fetchConfigsByKeys(Object.keys(PUSH_CONFIG_DEFAULTS))
  // 补默认值：旧库里这两行不存在时不能返回 undefined，否则后台表单一进来就是空白
  return c.json(Object.entries(PUSH_CONFIG_DEFAULTS).map(([config_key, defaultValue]) => ({
    config_key,
    config_value: data.find((item) => item.config_key === config_key)?.config_value ?? defaultValue,
  })))
})

app.get('/s3-info', async (c) => {
  const data = await fetchConfigsByKeys([
    'accesskey_id',
    'accesskey_secret',
    'region',
    'endpoint',
    'bucket',
    'storage_folder',
    'force_path_style',
    's3_cdn',
    's3_cdn_url',
    's3_direct_download'
  ])
  return c.json(data)
})

app.get('/get-admin-config', async (c) => {
  try {
    const data = await fetchConfigsByKeys([
      'admin_images_per_page'
    ])
    return c.json(data)
  } catch (error) {
    console.error('Error fetching admin config:', error)
    throw new HTTPException(500, { message: 'Failed to fetch admin config', cause: error })
  }
})

app.put('/update-open-list-info', async (c) => {
  const query = await c.req.json()

  const openListUrl = query?.find((item: Config) => item.config_key === 'open_list_url').config_value
  const openListToken = query?.find((item: Config) => item.config_key === 'open_list_token').config_value

  const data = await updateOpenListConfig({ openListUrl, openListToken })
  invalidateConfigs()
  return c.json(data)
})

app.put('/update-r2-info', async (c) => {
  const query = await c.req.json()

  const r2AccesskeyId = query?.find((item: Config) => item.config_key === 'r2_accesskey_id').config_value
  const r2AccesskeySecret = query?.find((item: Config) => item.config_key === 'r2_accesskey_secret').config_value
  const r2AccountId = query?.find((item: Config) => item.config_key === 'r2_account_id').config_value
  const r2Bucket = query?.find((item: Config) => item.config_key === 'r2_bucket').config_value
  const r2StorageFolder = query?.find((item: Config) => item.config_key === 'r2_storage_folder').config_value
  const r2PublicDomain = query?.find((item: Config) => item.config_key === 'r2_public_domain').config_value
  const r2DirectDownload = query?.find((item: Config) => item.config_key === 'r2_direct_download').config_value

  const data = await updateR2Config({ r2AccesskeyId, r2AccesskeySecret, r2AccountId, r2Bucket, r2StorageFolder, r2PublicDomain, r2DirectDownload })
  invalidateConfigs()
  return c.json(data)
})

app.put('/update-push-info', async (c) => {
  const query = await c.req.json()

  const pushEnabled = query?.find((item: Config) => item.config_key === 'push_enabled').config_value
  const pushCooldownSeconds = query?.find((item: Config) => item.config_key === 'push_cooldown_seconds').config_value

  // 只收字符串字面量 'true'/'false'（表里的布尔语义，见 updatePushConfig）；
  // 冷却只收十进制整数：'12.5' / '1e3' / '' 一律拒绝，别让 parseInt 式的宽松解析漏进来
  if (pushEnabled !== 'true' && pushEnabled !== 'false') {
    throw new HTTPException(400, { message: 'push_enabled must be "true" or "false"' })
  }
  if (!/^\d+$/.test(String(pushCooldownSeconds)) || Number(pushCooldownSeconds) > PUSH_COOLDOWN_SECONDS_MAX) {
    throw new HTTPException(400, { message: `push_cooldown_seconds must be an integer between 0 and ${PUSH_COOLDOWN_SECONDS_MAX}` })
  }

  const data = await updatePushConfig({ pushEnabled, pushCooldownSeconds: String(Number(pushCooldownSeconds)) })
  invalidateConfigsImmediately()
  return c.json(data)
})

app.put('/update-s3-info', async (c) => {
  const query = await c.req.json()

  const accesskeyId = query?.find((item: Config) => item.config_key === 'accesskey_id').config_value
  const accesskeySecret = query?.find((item: Config) => item.config_key === 'accesskey_secret').config_value
  const region = query?.find((item: Config) => item.config_key === 'region').config_value
  const endpoint = query?.find((item: Config) => item.config_key === 'endpoint').config_value
  const bucket = query?.find((item: Config) => item.config_key === 'bucket').config_value
  const storageFolder = query?.find((item: Config) => item.config_key === 'storage_folder').config_value
  const forcePathStyle = query?.find((item: Config) => item.config_key === 'force_path_style').config_value
  const s3Cdn = query?.find((item: Config) => item.config_key === 's3_cdn').config_value
  const s3CdnUrl = query?.find((item: Config) => item.config_key === 's3_cdn_url').config_value
  const s3DirectDownload = query?.find((item: Config) => item.config_key === 's3_direct_download').config_value

  const data = await updateS3Config({ accesskeyId, accesskeySecret, region, endpoint, bucket, storageFolder, forcePathStyle, s3Cdn, s3CdnUrl, s3DirectDownload })
  invalidateConfigs()
  return c.json(data)
})

app.put('/update-custom-info', async (c) => {
  const query = await c.req.json() satisfies {
    title: string
    customFaviconUrl: string
    customAuthor: string
    feedId: string
    userId: string
    customIndexStyle: number
    customIndexDownloadEnable: boolean
    enablePreviewImageMaxWidthLimit: boolean
    previewImageMaxWidth: number
    previewQuality: number
    umamiHost: string
    umamiAnalytics: string
    maxUploadFiles: number
    customIndexOriginEnable: boolean
    adminImagesPerPage: number
  }
  try {
    await updateCustomInfo(query)
    invalidateConfigs()
    return c.json({
      code: 200,
      message: 'Success'
    })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

export default app
