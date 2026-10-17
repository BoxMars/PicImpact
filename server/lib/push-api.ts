import { z } from 'zod'

import { IMAGE_ID_PATTERN, apiError } from '~/server/lib/admin-api'

/**
 * 推送接口（`/api/v1/push/*`）的请求校验与出参映射。
 *
 * 与 `server/lib/admin-api.ts` 一样，本模块**不 import 任何 `server-only` 的东西** ——
 * 校验规则与出参形状要能在 `node --test` 下直接断言，不必起 Next、连数据库。
 * （`apiError` 就是那边导出的通用 HTTPException 工厂，与 admin 业务无关。）
 *
 * 契约见 `docs/superpowers/plans/2026-10-13-ios-push-and-gallery-sort.md`。
 */

export { apiError }

/**
 * APNs device token 是十六进制串。
 *
 * 长度只做**宽松**校验：官方明确写「Don't make assumptions about device token size」，
 * 所以这里只挡字符集与明显异常的区间，不按某个具体长度卡。
 */
export const DEVICE_TOKEN_PATTERN = /^[0-9a-fA-F]{32,200}$/

/** 客户端自报的安装标识（App 生成、存 Keychain 的 UUID 之类） */
export const CLIENT_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/

export const APNS_ENVIRONMENTS = ['sandbox', 'production'] as const
export type APNsEnvironmentName = (typeof APNS_ENVIRONMENTS)[number]

/**
 * 注册 / 更新一台设备。
 *
 * ⚠️ **不接受** `bundleId` 与 `userId`：
 * - `bundleId` 由服务端从 `APNS_BUNDLE_ID` 填 —— 它同时是 `apns-topic`，
 *   让客户端指定等于让客户端决定往哪个 topic 推；
 * - `userId` 只从会话取。
 */
export const registerDeviceSchema = z.object({
  token: z.string().regex(DEVICE_TOKEN_PATTERN),
  environment: z.enum(APNS_ENVIRONMENTS),
  clientId: z.string().regex(CLIENT_ID_PATTERN),
  deviceName: z.string().max(100).optional(),
  systemVersion: z.string().max(32).optional(),
  appVersion: z.string().max(32).optional(),
  locale: z.string().max(16).optional(),
})

export type RegisterDeviceInput = z.infer<typeof registerDeviceSchema>

export const deviceQuerySchema = z.object({
  clientId: z.string().regex(CLIENT_ID_PATTERN),
})

/**
 * 「对指定照片发一条通知」的请求体。
 *
 * `imageId` 决定点开通知跳到哪张图；`body` 可选 —— 不传就用后台配的模板渲染。
 * 传了也仍然会做 `{{title}}` / `{{album}}` 替换，所以可以直接写模板。
 */
export const sendNotificationSchema = z.object({
  imageId: z.string().regex(IMAGE_ID_PATTERN),
  body: z.string().trim().min(1).max(300).optional(),
})

export type SendNotificationInput = z.infer<typeof sendNotificationSchema>

export type PushDeviceSummary = {
  id: string
  deviceName: string | null
  systemVersion: string | null
  appVersion: string | null
  environment: string
  enabled: number
  clientId: string
  lastSeenAt: string | null
  /** 只回后 8 位：排障够用，又不把「能往这台设备推」的能力摊在界面上 */
  tokenSuffix: string
}

function isoOrNull(value: unknown): string | null {
  if (value instanceof Date) return value.toISOString()
  if (typeof value === 'string' && value) return value
  return null
}

export function toPushDeviceSummary(row: Record<string, any>): PushDeviceSummary {
  const token = typeof row.token === 'string' ? row.token : ''
  return {
    id: String(row.id ?? ''),
    deviceName: row.deviceName ?? null,
    systemVersion: row.systemVersion ?? null,
    appVersion: row.appVersion ?? null,
    environment: String(row.environment ?? ''),
    enabled: Number(row.enabled ?? 0),
    clientId: String(row.clientId ?? ''),
    lastSeenAt: isoOrNull(row.lastSeenAt),
    tokenSuffix: token.length > 8 ? token.slice(-8) : token,
  }
}
