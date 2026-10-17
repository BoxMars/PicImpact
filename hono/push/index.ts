import 'server-only'

import { auth } from '~/server/auth'
import { fetchConfigValue } from '~/server/db/query/configs'
import { apnsBundleId, isAPNsConfigured, readAPNsConfigFromEnv } from '~/server/lib/apns'
import { db } from '~/server/lib/db'
import { STALE_DEVICE_MS, notifyNewImage } from '~/server/lib/new-image-notify'

import { createPushApi } from './api'

/**
 * `/api/v1/push/*` 的真实依赖装配。
 *
 * 路由逻辑在 `./api.ts`（纯工厂，可单测）；**这个文件才 import server-only 与 Prisma**，
 * 所以它不会被单测加载 —— 真实校验与真实入库只由 curl 打真接口来验。
 */

/** 诊断接口要看的字段（含已停用的，便于看出"为什么收不到"） */
const DEVICE_FIELDS = {
  id: true,
  token: true,
  environment: true,
  bundleId: true,
  clientId: true,
  deviceName: true,
  systemVersion: true,
  appVersion: true,
  locale: true,
  enabled: true,
  lastSeenAt: true,
} as const

export default createPushApi({
  async getSession(headers) {
    // 这里才是真正的会话校验：proxy.ts 用的 getSessionCookie() 只判断 cookie 在不在、不验签
    const session = await auth.api.getSession({ headers })
    if (!session?.user) return null
    return { userId: session.user.id, email: session.user.email }
  },

  async upsertDevice(input) {
    const common = {
      environment: input.environment,
      bundleId: apnsBundleId(),
      clientId: input.clientId,
      deviceName: input.deviceName ?? null,
      systemVersion: input.systemVersion ?? null,
      appVersion: input.appVersion ?? null,
      locale: input.locale ?? null,
    }

    // 按 token upsert：重装/换环境 → 更新这一行；重新注册 → 重新启用（关通知时置 0）。
    // ⚠️ 不再写 userId：设备与账号无关（推送发给所有装了 App 的人）。
    return await db.pushDevice.upsert({
      where: { token: input.token },
      create: { ...common, token: input.token, enabled: 1 },
      update: { ...common, enabled: 1, lastSeenAt: new Date() },
      select: DEVICE_FIELDS,
    })
  },

  async disableDevice({ clientId }) {
    // 只按 clientId（App 生成、存 Keychain 的 UUID）定位：公开接口，不该能按别的维度批量改
    const result = await db.pushDevice.updateMany({
      where: { clientId },
      data: { enabled: 0 },
    })
    return result.count
  },

  async listDevices() {
    return await db.pushDevice.findMany({
      orderBy: { lastSeenAt: 'desc' },
      select: DEVICE_FIELDS,
    })
  },

  async isPushEnabled() {
    // 两道门都要过：总开关打开 + 凭据齐备。任一不满足都返回 false，
    // 让 App 能明确告诉用户"服务端还没开推送"，而不是静默什么都收不到。
    const enabled = await fetchConfigValue('push_enabled', 'false')
    return enabled === 'true' && isAPNsConfigured(readAPNsConfigFromEnv())
  },

  async deviceExists(token) {
    const row = await db.pushDevice.findUnique({ where: { token }, select: { id: true } })
    return Boolean(row)
  },

  async loadImageForPush(imageId) {
    // 只允许推**公开且未删除**的图：通知里会带标题与预览图 URL，未公开的图不该露出去
    const image = await db.images.findFirst({
      where: { id: imageId, del: 0, show: 0 },
      select: { id: true, title: true, image_name: true, preview_url: true, show: true, del: true },
    })
    if (!image) return null

    const relation = await db.imagesAlbumsRelation.findFirst({
      where: { imageId },
      select: { album_value: true },
    })

    return {
      id: image.id,
      title: image.title,
      imageName: image.image_name,
      previewUrl: image.preview_url,
      albumValue: relation?.album_value ?? null,
      show: image.show,
      del: image.del,
    }
  },

  async sendPushNow(notice, options) {
    // 与自动触发共用同一份实现：冷却、失败隔离、日志都在里面；这里只多传 body 与跳过冷却
    return await notifyNewImage(notice, { body: options.body ?? null, ignoreCooldown: true })
  },

  async countLiveDevices() {
    // 只数「启用且 90 天内活过」的：这样换机/重装留下的僵尸行不会挤占上限
    return await db.pushDevice.count({
      where: { enabled: 1, lastSeenAt: { gte: new Date(Date.now() - STALE_DEVICE_MS) } },
    })
  },
})
