/**
 * APNs（Apple Push Notification service）客户端。
 *
 * ## 为什么手写、为什么用 `node:http2`
 *
 * APNs 只接受 **HTTP/2 + TLS 1.2+**，而且 HTTP/1.1 是**连接层就失败**（不是返回 4xx）。
 * 本机实测（2026-10-13，Node v25.8.1）：
 *
 * ```
 * curl --http1.1 https://api.push.apple.com/3/device/00   → code=000（没有 HTTP 响应）
 * curl --http2    https://api.push.apple.com/3/device/00   → 403 {"reason":"MissingProviderToken"}
 * node fetch(...)                                          → TypeError: fetch failed   ← undici 默认 HTTP/1.1
 * node:http2                                              → 403 {"reason":"MissingProviderToken"}
 * ```
 *
 * 所以**这个文件里不允许出现 `fetch(`**（有结构性单测钉住）。也因此不能把路由改成 edge runtime。
 *
 * ## 两条连接、两套凭据
 *
 * Apple 现在发的 key 是**分环境**的（sandbox / production），而一条 HTTP/2 连接在第一次推送时
 * 就被绑定到 team + bundle：混用会在**第二次**推送才报错，症状极难定位。
 * 因此本模块按 `environment` 各维护一条连接、各选一套凭据。
 *
 * ## provider token（JWT）
 *
 * 官方对刷新节奏有**双向**约束：不能比每 20 分钟更频繁，也不能超过 60 分钟不换；
 * `iat` 超过 1 小时直接 403 ExpiredProviderToken。这里取 50 分钟缓存。
 *
 * 参考资料：
 * - https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
 * - https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
 */

import { randomUUID, sign as signWithKey } from 'node:crypto'
import http2 from 'node:http2'
import type { ClientHttp2Session } from 'node:http2'

export type APNsEnvironment = 'sandbox' | 'production'

/** 官方端点。测试可用 `config.endpoints` 覆盖成明文 h2c 本地服务。 */
export const APNS_ENDPOINTS: Record<APNsEnvironment, string> = {
  sandbox: 'https://api.sandbox.push.apple.com:443',
  production: 'https://api.push.apple.com:443',
}

/** 载荷上限：官方 4 KB，**超过会被 APNs 直接拒**，不能靠运气。 */
export const APNS_MAX_PAYLOAD_BYTES = 4096

/** 单次发送的硬超时。serverless 里绝不能让一次推送挂住整个请求。 */
export const APNS_REQUEST_TIMEOUT_MS = 2500

/** provider token 缓存时长：官方要求 ≥20 分钟、≤60 分钟换一次，取 50 分钟（两边都满足）。 */
export const APNS_TOKEN_TTL_MS = 50 * 60 * 1000

/** `apns-topic` 必须与 App 的 bundle id 一致 */
export const DEFAULT_APNS_BUNDLE_ID = 'dev.boxz.felina'

export interface APNsConfig {
  /** `.p8` 私钥内容（PEM），生产环境用 */
  keyP8: string
  /** 10 字符 Key ID */
  keyId: string
  /** 10 字符 Team ID */
  teamId: string
  /** 即 `apns-topic`，必须是 App 的 bundle id */
  bundleId: string
  /** 沙箱专用 key；留空表示沙箱复用生产 key（老 key 支持双环境时才这么做） */
  sandboxKeyP8?: string
  sandboxKeyId?: string
  /** 仅测试用：覆盖端点 */
  endpoints?: Partial<Record<APNsEnvironment, string>>
}

export interface APNsNotification {
  deviceToken: string
  environment: APNsEnvironment
  /** 完整载荷，含 `aps` */
  payload: Record<string, unknown>
  pushType?: 'alert' | 'background'
  priority?: 10 | 5
  /** 相对秒数：0 = 只投一次不存储；不传 = 交给 APNs 的默认存储策略 */
  expirationSeconds?: number
  collapseId?: string
  apnsId?: string
}

export interface APNsResult {
  ok: boolean
  /** HTTP 状态；null 表示根本没拿到响应（连接失败 / 超时 / 本地校验失败） */
  status: number | null
  apnsId: string | null
  /** APNs 的 `reason`，或本地错误摘要（NotConfigured / Timeout / …） */
  reason: string | null
  detail: string | null
}

// ---------------------------------------------------------------------------
// 纯函数（可直接单测）
// ---------------------------------------------------------------------------

function base64Url(input: Buffer): string {
  return input.toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
}

/**
 * 签一个 provider token（JWT，ES256）。
 *
 * ⚠️ 必须用 `dsaEncoding: 'ieee-p1363'`：Node 默认输出的是 **DER** 签名，
 * 而 JOSE 要的是 64 字节裸 `r||s`。用默认值签出来的 token APNs 一律拒。
 */
export function signProviderToken(options: {
  keyId: string
  teamId: string
  p8: string
  issuedAtSeconds: number
}): string {
  const header = base64Url(Buffer.from(JSON.stringify({ alg: 'ES256', kid: options.keyId })))
  const claims = base64Url(
    Buffer.from(JSON.stringify({ iss: options.teamId, iat: options.issuedAtSeconds }))
  )
  const signingInput = `${header}.${claims}`
  const signature = signWithKey('sha256', Buffer.from(signingInput), {
    key: options.p8,
    dsaEncoding: 'ieee-p1363',
  })
  return `${signingInput}.${base64Url(signature)}`
}

/** device token 是十六进制串。官方明确说「不要假设 token 长度」，所以只校验字符集与合理区间。 */
export function isValidDeviceToken(token: string): boolean {
  return /^[0-9a-fA-F]{32,200}$/.test(token)
}

export function isAPNsConfigured(config: APNsConfig | null | undefined): config is APNsConfig {
  if (!config) return false
  return Boolean(config.keyP8 && config.keyId && config.teamId && config.bundleId)
}

/** 取该环境该用的凭据。沙箱没单独配就复用生产的（老 key 支持双环境）。 */
export function selectCredentials(
  config: APNsConfig,
  environment: APNsEnvironment
): { keyId: string; keyP8: string } {
  if (environment === 'sandbox' && config.sandboxKeyP8 && config.sandboxKeyId) {
    return { keyId: config.sandboxKeyId, keyP8: config.sandboxKeyP8 }
  }
  return { keyId: config.keyId, keyP8: config.keyP8 }
}

export function buildAPNsHeaders(
  notification: APNsNotification,
  options: { bundleId: string; providerToken: string; apnsId: string; nowMs: number }
): Record<string, string> {
  const pushType = notification.pushType ?? 'alert'
  // background 推送**必须** priority 5（官方原文：using priority 10 is an error）。
  // 这里不报错而是纠正：少发一条通知比因为一个参数写错而整条不发好。
  const priority = pushType === 'background' ? 5 : (notification.priority ?? 10)
  const headers: Record<string, string> = {
    ':method': 'POST',
    ':path': `/3/device/${notification.deviceToken}`,
    'apns-topic': options.bundleId,
    'apns-push-type': pushType,
    'apns-priority': String(priority),
    authorization: `bearer ${options.providerToken}`,
    'apns-id': options.apnsId,
  }
  if (notification.expirationSeconds !== undefined) {
    headers['apns-expiration'] = String(
      Math.floor(options.nowMs / 1000) + notification.expirationSeconds
    )
  }
  if (notification.collapseId) {
    // 官方限制 ≤64 字节
    headers['apns-collapse-id'] = notification.collapseId.slice(0, 64)
  }
  return headers
}

/** `apns-topic`：与 App 的 bundle id 一致。设备行里存的也是它。 */
export function apnsBundleId(env: Record<string, string | undefined> = process.env): string {
  return env.APNS_BUNDLE_ID?.trim() || DEFAULT_APNS_BUNDLE_ID
}

/** 从环境变量读配置。缺任何一个必填项就返回 null（= 推送不可用，调用方静默跳过）。 */
export function readAPNsConfigFromEnv(
  env: Record<string, string | undefined> = process.env
): APNsConfig | null {
  const unescape = (value: string | undefined) => value?.replace(/\\n/g, '\n').trim()
  const config: APNsConfig = {
    keyP8: unescape(env.APNS_KEY_P8) ?? '',
    keyId: env.APNS_KEY_ID?.trim() ?? '',
    teamId: env.APNS_TEAM_ID?.trim() ?? '',
    bundleId: apnsBundleId(env),
    sandboxKeyP8: unescape(env.APNS_SANDBOX_KEY_P8),
    sandboxKeyId: env.APNS_SANDBOX_KEY_ID?.trim() || undefined,
  }
  return isAPNsConfigured(config) ? config : null
}

export function interpretAPNsResponse(
  status: number | null,
  rawBody: string,
  apnsId: string | null
): APNsResult {
  if (status === 200) {
    return { ok: true, status, apnsId, reason: null, detail: null }
  }
  let reason: string | null = null
  const body = rawBody.trim()
  if (body) {
    try {
      const parsed = JSON.parse(body) as { reason?: unknown }
      if (typeof parsed.reason === 'string') reason = parsed.reason
    } catch {
      // 不是 JSON 就原样留在 detail 里
    }
  }
  return { ok: false, status, apnsId, reason, detail: body.slice(0, 300) || null }
}

// ---------------------------------------------------------------------------
// 连接与 token 缓存（模块级，随函数实例存活）
// ---------------------------------------------------------------------------

const sessions = new Map<string, ClientHttp2Session>()
const providerTokens = new Map<string, { token: string; cachedAt: number }>()

function dropSession(origin: string): void {
  const session = sessions.get(origin)
  sessions.delete(origin)
  if (session && !session.destroyed) {
    try {
      session.destroy()
    } catch {
      // 已经坏了就算了
    }
  }
}

/**
 * 取一条可用连接。
 *
 * serverless 的实例会被冻结/回收，连接随时可能已经失效（`GOAWAY` / `close`）。
 * 监听这三个事件并**丢弃缓存**，下次调用重建 —— 不重建的症状是
 * 「上线后第一条推送成功、之后全失败」，而且不会报错，只会一直 failed。
 */
function getSession(origin: string): ClientHttp2Session {
  const existing = sessions.get(origin)
  if (existing && !existing.closed && !existing.destroyed) return existing

  const session = http2.connect(origin)
  const forget = () => dropSession(origin)
  session.on('error', forget)
  session.on('close', forget)
  session.on('goaway', forget)
  sessions.set(origin, session)
  return session
}

function providerTokenFor(config: APNsConfig, environment: APNsEnvironment, nowMs: number): string {
  const { keyId, keyP8 } = selectCredentials(config, environment)
  const cacheKey = `${environment}:${keyId}`
  const cached = providerTokens.get(cacheKey)
  if (cached && nowMs - cached.cachedAt < APNS_TOKEN_TTL_MS) return cached.token

  const token = signProviderToken({
    keyId,
    teamId: config.teamId,
    p8: keyP8,
    issuedAtSeconds: Math.floor(nowMs / 1000),
  })
  providerTokens.set(cacheKey, { token, cachedAt: nowMs })
  return token
}

/** 仅供测试：清空连接与 provider token 缓存。 */
export function resetAPNsCachesForTest(): void {
  for (const origin of [...sessions.keys()]) dropSession(origin)
  providerTokens.clear()
}

// ---------------------------------------------------------------------------
// 发送
// ---------------------------------------------------------------------------

function failure(status: number | null, reason: string, detail: string | null = null): APNsResult {
  return { ok: false, status, apnsId: null, reason, detail }
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return String(error)
}

export interface SendPushOptions {
  now?: number
  timeoutMs?: number
}

/**
 * 发一条推送。**不抛异常** —— 任何失败都以 `{ ok: false, reason }` 返回，
 * 调用方（入库路径）据此只记日志，绝不影响上传。
 */
export async function sendPush(
  notification: APNsNotification,
  config: APNsConfig | null,
  options: SendPushOptions = {}
): Promise<APNsResult> {
  if (!isAPNsConfigured(config)) return failure(null, 'NotConfigured')
  if (!isValidDeviceToken(notification.deviceToken)) return failure(null, 'InvalidDeviceToken')

  const nowMs = options.now ?? Date.now()
  const apnsId = notification.apnsId ?? randomUUID()

  let body: Buffer
  try {
    body = Buffer.from(JSON.stringify(notification.payload), 'utf8')
  } catch (error) {
    return failure(null, 'InvalidPayload', errorMessage(error))
  }
  if (body.byteLength > APNS_MAX_PAYLOAD_BYTES) {
    return failure(null, 'PayloadTooLarge', `${body.byteLength} > ${APNS_MAX_PAYLOAD_BYTES}`)
  }

  const first = await attempt(notification, config, { apnsId, body, nowMs, ...options })
  // provider token 过期：清掉缓存重签一次再试。这是唯一值得自动重试的错误。
  if (!first.ok && first.reason === 'ExpiredProviderToken') {
    providerTokens.clear()
    return await attempt(notification, config, { apnsId, body, nowMs: Date.now(), ...options })
  }
  return first
}

async function attempt(
  notification: APNsNotification,
  config: APNsConfig,
  context: { apnsId: string; body: Buffer; nowMs: number; timeoutMs?: number }
): Promise<APNsResult> {
  const timeoutMs = context.timeoutMs ?? APNS_REQUEST_TIMEOUT_MS
  const origin =
    config.endpoints?.[notification.environment] ?? APNS_ENDPOINTS[notification.environment]

  let headers: Record<string, string>
  try {
    headers = buildAPNsHeaders(notification, {
      bundleId: config.bundleId,
      providerToken: providerTokenFor(config, notification.environment, context.nowMs),
      apnsId: context.apnsId,
      nowMs: context.nowMs,
    })
  } catch (error) {
    // 私钥格式不对会在这里抛
    return failure(null, 'InvalidKey', errorMessage(error))
  }

  return await new Promise<APNsResult>((resolve) => {
    let settled = false
    const finish = (result: APNsResult) => {
      if (settled) return
      settled = true
      resolve(result)
    }

    let request: http2.ClientHttp2Stream
    try {
      request = getSession(origin).request(headers)
    } catch (error) {
      dropSession(origin)
      return finish(failure(null, 'ConnectionFailed', errorMessage(error)))
    }

    const timer = setTimeout(() => {
      // 超时：取消这条流。连接本身留着（APNs 允许并发流），但流必须收掉。
      try {
        request.close(http2.constants.NGHTTP2_CANCEL)
      } catch {
        // ignore
      }
      finish(failure(null, 'Timeout', `${timeoutMs}ms`))
    }, timeoutMs)

    let status: number | null = null
    const chunks: Buffer[] = []

    request.on('response', (responseHeaders) => {
      const raw = responseHeaders[':status']
      status = typeof raw === 'number' ? raw : Number(raw)
    })
    request.on('data', (chunk: Buffer) => chunks.push(chunk))
    request.on('error', (error) => {
      clearTimeout(timer)
      dropSession(origin)
      finish(failure(status, 'RequestError', errorMessage(error)))
    })
    request.on('end', () => {
      clearTimeout(timer)
      const rawBody = Buffer.concat(chunks).toString('utf8')
      const result = interpretAPNsResponse(status, rawBody, context.apnsId)
      if (status !== null && status >= 500) dropSession(origin)
      finish(result)
    })

    request.end(context.body)
  })
}
