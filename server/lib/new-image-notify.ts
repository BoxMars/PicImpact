import { APNS_MAX_PAYLOAD_BYTES, type APNsConfig, type APNsNotification, type APNsResult } from '~/server/lib/apns'
import { DEFAULT_PUSH_BODY_TEMPLATE, renderPushBody } from '~/server/lib/push-template'

/**
 * 「有新照片入库」→ 推送通知。
 *
 * ## 挂在哪
 * 挂在**两个**写图片入口的「写后副作用」处（与 `revalidateTag` 并列），
 * 而不是 `insertImage` 里面 —— 那个函数在 `$transaction` 里，且是 `'use server'` 数据层。
 *   - `hono/images.ts`（Web 后台上传）
 *   - `hono/admin/index.ts`（App 上传登记）
 *
 * 新增第三个入口时**必须**也接上；`tests/api/push-notify.test.ts` 用结构性断言钉住了这件事。
 *
 * ## 三条硬约束
 * 1. **永远不抛**：推送挂掉绝不能让上传失败。
 * 2. **不刷屏**：同一台设备 `push_cooldown_seconds` 内最多一条（默认 120 秒）。
 * 3. **自己传的不通知自己**：请求头 `X-Felina-Client-Id` 与设备行里的 `clientId` 相同则跳过。
 *
 * ## 为什么是"广播给所有设备"是对的
 * 这个 App 是**给自己、家人和朋友看**的：装了 App 的人都该知道「有新照片」。
 * 登录只是上传/管理才需要，跟收通知无关 —— 所以设备表里 `userId` 可空，也不参与筛选。
 * 图片本身是全局资源（`Images` 表没有归属字段，`prisma/schema.prisma`），
 * 「有新照片」是一个**站点级事件**，不是某个用户的事件。
 * 这里取所有启用的设备，再用 `clientId` 摘掉"正在上传的那一台"。
 *
 * 本模块**不 import `server-only` 的任何东西**（真实依赖走动态 import），
 * 因此 `createNewImageNotifier` 可以在 `node --test` 下直接断言。
 */

/** 超过这个时长没出现过的设备视同失效（重装/换机后 token 不会回来） */
export const STALE_DEVICE_MS = 90 * 24 * 60 * 60 * 1000

/** 默认冷却：同一台设备的两次推送最小间隔（秒） */
export const DEFAULT_COOLDOWN_SECONDS = 120

/** 同一批通知在设备上合并成一条 */
export const NEW_IMAGE_COLLAPSE_ID = 'new-images'

/** 通知的有效期：1 小时。更久的「有新照片」已经没意义，不如省掉 APNs 的存储 */
export const NEW_IMAGE_EXPIRATION_SECONDS = 3600

export interface NewImageNotice {
  id: string
  title?: string | null
  imageName?: string | null
  previewUrl?: string | null
  albumValue?: string | null
  /** `Images.show`：0 = 公开。只推公开图 */
  show?: number | null
  /** `Images.del`：0 = 未删除 */
  del?: number | null
}

export interface PushDeviceRow {
  id: string
  /** 可空：没登录过站点的普通 App 用户就是 null（设备与账号无关） */
  userId: string | null
  token: string
  environment: string
  clientId: string
  enabled: number
  lastSeenAt: Date | string | null
}

export interface DeliveryLogRow {
  userId: string | null
  deviceId: string
  imageId: string
  environment: string
  status: 'sent' | 'failed' | 'pruned'
  httpStatus: number | null
  apnsId: string | null
  reason: string | null
}

export interface NotifyDeps {
  now(): number
  loadConfig(): Promise<{
    enabled: boolean
    cooldownSeconds: number
    siteTitle: string
    /** 正文模板（`configs.push_body_template`），空则用默认 */
    bodyTemplate: string
  }>
  apnsConfig(): APNsConfig | null
  listDevices(): Promise<PushDeviceRow[]>
  albumName(albumValue: string): Promise<string | null>
  /** 该设备最近一次**成功**推送的时间（ms epoch）；没有则 null */
  lastSentAt(deviceId: string): Promise<number | null>
  logDelivery(row: DeliveryLogRow): Promise<void>
  disableDevice(deviceId: string): Promise<void>
  send(notification: APNsNotification, config: APNsConfig): Promise<APNsResult>
}

export interface NotifyOutcome {
  /** 一眼看出"为什么没推"：disabled / unconfigured / not_public / no_devices / sent / skipped / failed */
  status: 'disabled' | 'unconfigured' | 'not_public' | 'no_devices' | 'sent' | 'skipped' | 'failed'
  sent: number
  skipped: number
  failed: number
}

export function buildNewImagePayload(
  notice: NewImageNotice,
  context: {
    siteTitle: string
    /** 相册名：**不再作副标题**（用户要求），只作为 `{{album}}` 占位符的取值 */
    albumName: string | null
    /** 后台可配的正文模板（`configs.push_body_template`） */
    bodyTemplate?: string | null
    /** 手动发送时整句覆盖（仍然会做占位符替换，方便直接写模板） */
    bodyOverride?: string | null
  }
): Record<string, unknown> {
  const body = renderPushBody(context.bodyOverride ?? context.bodyTemplate, {
    title: notice.title || notice.imageName,
    album: context.albumName,
  })

  const payload: Record<string, unknown> = {
    aps: {
      // 只有标题 + 正文；相册名不再占一个副标题位（想看的话写进模板的 {{album}} 即可）
      alert: {
        title: context.siteTitle,
        body,
      },
      sound: 'default',
      'thread-id': NEW_IMAGE_COLLAPSE_ID,
      'interruption-level': 'active',
      // 现在没有 Notification Service Extension，这个键会被忽略 —— 留着是为将来加缩略图
      'mutable-content': 1,
    },
    v: 1,
    imageId: notice.id,
  }
  if (notice.albumValue) payload.albumValue = notice.albumValue
  if (notice.previewUrl) payload.previewUrl = notice.previewUrl
  return fitPayload(payload)
}

function payloadBytes(payload: Record<string, unknown>): number {
  return new TextEncoder().encode(JSON.stringify(payload)).length
}

/**
 * 把载荷压进 APNs 的 4 KB 上限。
 *
 * 为什么需要：**超限的载荷 APNs 直接拒**（不是截断），而标题来自 `Images.title`
 * （`VarChar(200)`）、相册名来自 `Albums.name`（`VarChar(200)`），再叠上预览图 URL，
 * 中文按 UTF-8 是 3 字节/字 —— 极端情况下真会顶到 4 KB。
 * 顺序：先丢预览图 URL（客户端拿到推送后本来也会自己去拉图），再对正文折半截断。
 */
export function fitPayload(
  payload: Record<string, unknown>,
  maxBytes: number = APNS_MAX_PAYLOAD_BYTES
): Record<string, unknown> {
  if (payloadBytes(payload) <= maxBytes) return payload

  const copy = JSON.parse(JSON.stringify(payload)) as Record<string, any>
  if (copy.previewUrl) {
    delete copy.previewUrl
    if (payloadBytes(copy) <= maxBytes) return copy
  }

  const body = copy?.aps?.alert?.body
  if (typeof body === 'string') {
    // 折半截断：既快又必然收敛，不需要逐字符试
    while (payloadBytes(copy) > maxBytes && copy.aps.alert.body.length > 1) {
      copy.aps.alert.body = copy.aps.alert.body.slice(0, Math.floor(copy.aps.alert.body.length / 2))
    }
  }
  return copy
}

/** 冷却秒数：非法值一律回落到默认，绝不让一个坏配置把推送变成"每张都发"或"永远不发" */
export function parseCooldownSeconds(raw: string | null | undefined): number {
  const parsed = Number.parseInt(raw ?? '', 10)
  if (!Number.isFinite(parsed) || parsed < 0) return DEFAULT_COOLDOWN_SECONDS
  return Math.min(parsed, 86_400)
}

export function isPublicNotice(notice: NewImageNotice): boolean {
  // 库里 show 的默认值是 1（隐藏），所以这里必须有明确判断，不能"没写就是公开"
  return (notice.show ?? 1) === 0 && (notice.del ?? 1) === 0
}

export function isStaleDevice(lastSeenAt: Date | string | null, nowMs: number): boolean {
  if (!lastSeenAt) return true
  const time = lastSeenAt instanceof Date ? lastSeenAt.getTime() : Date.parse(lastSeenAt)
  if (!Number.isFinite(time)) return true
  return nowMs - time > STALE_DEVICE_MS
}

export function createNewImageNotifier(deps: NotifyDeps) {
  return async function notifyNewImage(
    notice: NewImageNotice | null | undefined,
    options: { clientId?: string | null } = {}
  ): Promise<NotifyOutcome> {
    const empty = (status: NotifyOutcome['status']): NotifyOutcome => ({
      status,
      sent: 0,
      skipped: 0,
      failed: 0,
    })

    if (!notice?.id) return empty('disabled')
    if (!isPublicNotice(notice)) return empty('not_public')

    // 先看总开关再看凭据：两者都没开时报 `disabled` 比报 `unconfigured` 更贴近事实
    // （"服务端没开推送"是人能直接去改的那个状态）。凭据只是解析环境变量，顺序不影响成本。
    const settings = await deps.loadConfig()
    if (!settings.enabled) return empty('disabled')

    const config = deps.apnsConfig()
    if (!config) return empty('unconfigured')

    const nowMs = deps.now()
    const devices = (await deps.listDevices()).filter((device) => {
      if (device.enabled !== 1) return false
      // 自己传的不通知自己
      if (options.clientId && device.clientId === options.clientId) return false
      if (isStaleDevice(device.lastSeenAt, nowMs)) return false
      return true
    })
    if (devices.length === 0) return empty('no_devices')

    const context = {
      siteTitle: settings.siteTitle,
      albumName: notice.albumValue ? await deps.albumName(notice.albumValue) : null,
      bodyTemplate: settings.bodyTemplate,
      bodyOverride: options.body ?? null,
    }
    const payload = buildNewImagePayload(notice, context)

    const outcome: NotifyOutcome = { status: 'sent', sent: 0, skipped: 0, failed: 0 }

    for (const device of devices) {
      const lastSentAt = options.ignoreCooldown ? null : await deps.lastSentAt(device.id)
      if (lastSentAt !== null && nowMs - lastSentAt < settings.cooldownSeconds * 1000) {
        // 冷却期内直接跳过：**不写日志**。否则一次批量上传能在日志表里塞进几十条噪声。
        outcome.skipped += 1
        continue
      }

      const environment = device.environment === 'sandbox' ? 'sandbox' : 'production'
      const result = await deps.send(
        {
          deviceToken: device.token,
          environment,
          payload,
          pushType: 'alert',
          priority: 10,
          expirationSeconds: NEW_IMAGE_EXPIRATION_SECONDS,
          collapseId: NEW_IMAGE_COLLAPSE_ID,
        },
        config
      )

      if (result.ok) {
        outcome.sent += 1
        await deps.logDelivery({
          userId: device.userId,
          deviceId: device.id,
          imageId: notice.id,
          environment,
          status: 'sent',
          httpStatus: result.status,
          apnsId: result.apnsId,
          reason: null,
        })
        continue
      }

      // token 已失效：停用而不是删除，留痕便于排障
      const pruned = result.status === 410 || result.reason === 'BadDeviceToken' || result.reason === 'Unregistered'
      if (pruned) await deps.disableDevice(device.id)

      outcome.failed += 1
      await deps.logDelivery({
        userId: device.userId,
        deviceId: device.id,
        imageId: notice.id,
        environment,
        status: pruned ? 'pruned' : 'failed',
        httpStatus: result.status,
        apnsId: result.apnsId,
        reason: result.reason,
      })
    }

    // 一次都没发出去时要区分原因：全被冷却挡下 ≠ 发失败。
    // （两者都会让 `sent == 0`，但一个该去看冷却配置，一个该去看 APNs 的 reason。）
    if (outcome.sent === 0 && outcome.failed > 0) outcome.status = 'failed'
    else if (outcome.sent === 0 && outcome.skipped > 0) outcome.status = 'skipped'
    return outcome
  }
}

// ---------------------------------------------------------------------------
// 真实装配
// ---------------------------------------------------------------------------

export interface NotifyOptions {
  /** 发起这次上传的客户端标识（请求头 `X-Felina-Client-Id`），用来排除"自己传的不通知自己" */
  clientId?: string | null
  /** 整句正文覆盖（后台「发送通知」用）；仍会做 `{{title}}` / `{{album}}` 替换 */
  body?: string | null
  /**
   * 跳过冷却。**只给手动发送用**：那是人主动点的一次动作，被"两分钟内刚推过"挡掉会很费解。
   * 自动触发（新图入库）永远不传这个。
   */
  ignoreCooldown?: boolean
}

/**
 * 真实入口：装配 Prisma / 配置 / APNs 客户端，然后发。
 *
 * **不抛异常**。这是入库路径上的副作用，任何失败只记日志 ——
 * 推送服务挂掉绝不能表现为"照片传不上去"。
 *
 * 依赖用**动态 import**：这样只跑 `createNewImageNotifier` 的单测不会去加载 Prisma。
 * （同样的写法见 `hono/require-session.ts`。）
 */
export async function notifyNewImage(
  notice: NewImageNotice | null | undefined,
  options: NotifyOptions = {}
): Promise<NotifyOutcome | null> {
  try {
    const [{ db }, { fetchConfigValue }, apnsModule] = await Promise.all([
      import('~/server/lib/db'),
      import('~/server/db/query/configs'),
      import('~/server/lib/apns'),
    ])

    const notifier = createNewImageNotifier({
      now: () => Date.now(),
      async loadConfig() {
        const [enabled, cooldown, siteTitle, bodyTemplate] = await Promise.all([
          fetchConfigValue('push_enabled', 'false'),
          fetchConfigValue('push_cooldown_seconds', String(DEFAULT_COOLDOWN_SECONDS)),
          fetchConfigValue('custom_title', '大福映画 Felina Gallery'),
          fetchConfigValue('push_body_template', DEFAULT_PUSH_BODY_TEMPLATE),
        ])
        return {
          enabled: enabled === 'true',
          cooldownSeconds: parseCooldownSeconds(cooldown),
          siteTitle: siteTitle || '大福映画 Felina Gallery',
          bodyTemplate: bodyTemplate || DEFAULT_PUSH_BODY_TEMPLATE,
        }
      },
      apnsConfig: () => apnsModule.readAPNsConfigFromEnv(),
      async listDevices() {
        return (await db.pushDevice.findMany({
          where: { enabled: 1 },
          select: {
            id: true,
            userId: true,
            token: true,
            environment: true,
            clientId: true,
            enabled: true,
            lastSeenAt: true,
          },
        })) as PushDeviceRow[]
      },
      async albumName(albumValue) {
        const album = await db.albums.findFirst({
          where: { album_value: albumValue },
          select: { name: true },
        })
        return album?.name ?? null
      },
      async lastSentAt(deviceId) {
        const row = await db.pushDelivery.findFirst({
          where: { deviceId, status: 'sent' },
          orderBy: { createdAt: 'desc' },
          select: { createdAt: true },
        })
        return row ? row.createdAt.getTime() : null
      },
      async logDelivery(row) {
        await db.pushDelivery.create({ data: row })
      },
      async disableDevice(deviceId) {
        await db.pushDevice.update({ where: { id: deviceId }, data: { enabled: 0 } })
      },
      send: (notification, config) => apnsModule.sendPush(notification, config),
    })

    const outcome = await notifier(notice, options)
    if (outcome.sent > 0 || outcome.failed > 0) {
      console.info(
        `[push] imageId=${notice?.id} status=${outcome.status} sent=${outcome.sent} skipped=${outcome.skipped} failed=${outcome.failed}`
      )
    }
    return outcome
  } catch (error) {
    // 这就是"推送失败不影响上传"的那道兜底
    console.warn('[push] 通知失败（上传不受影响）：', error)
    return null
  }
}
