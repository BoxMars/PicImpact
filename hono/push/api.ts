import { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'

import { createRequireSession, type SessionVariables } from '~/hono/require-session'
import {
  apiError,
  deviceQuerySchema,
  registerDeviceSchema,
  toPushDeviceSummary,
  type RegisterDeviceInput,
} from '~/server/lib/push-api'

/**
 * 推送接口（`/api/v1/push/*`）。
 *
 * ## 只有「看设备列表」需要登录
 * 推送的目标是**所有装了 App 的设备**（家人/朋友都该收到「有新照片」），
 * 所以 **注册与停用是公开的** —— 登录只是上传/管理才需要，跟收通知无关。
 *
 * 这是对初版设计的纠正：那版把设备绑在管理员账号上，等于「只有站长登录过的手机才收」，
 * 与实际需求（家庭/朋友共用这个 App）相反。
 *
 * ## 公开写入的代价与兜底
 * `/devices` 的 POST 任何人都能打，所以有三道闸：
 *   1. `token` 必须是十六进制 32–200（APNs 才认）；
 *   2. `environment` 白名单、`clientId` 形状校验；
 *   3. **设备上限** `MAX_DEVICES`：只统计「启用且 90 天内活过」的设备，超了拒绝新 token
 *      （已有 token 的心跳照常放行，否则老设备会互相挤掉）。
 * 再加一条自动清理：APNs 回 410 / BadDeviceToken 时把设备停用（见 `new-image-notify.ts`），
 * 所以伪造的 token 会在第一次推送后自我淘汰。
 *
 * 注：`GET /devices` 仍然挂会话 —— 它是诊断入口（"谁注册了、最近活过没有"），不该公开。
 */

export type PushSession = SessionVariables['session']

export interface PushApiDeps {
  /** **真正**校验会话。只有 GET /devices 用得到。 */
  getSession(headers: Headers): Promise<PushSession | null>
  /** 按 token upsert：同一台设备重装/重登时更新这一行。`userId` 已不再由这里写入。 */
  upsertDevice(input: RegisterDeviceInput): Promise<Record<string, any>>
  /** 停用指定 clientId 的设备（不物理删，保留排障线索）。返回受影响行数。 */
  disableDevice(input: { clientId: string }): Promise<number>
  /** 全部设备（含已停用），按最近活跃排序 */
  listDevices(): Promise<Record<string, any>[]>
  /** 服务端当前能不能推（`push_enabled` 开关 + APNs 凭据齐备） */
  isPushEnabled(): Promise<boolean>
  /** 这个 token 是否已注册过（决定上限检查要不要放行） */
  deviceExists(token: string): Promise<boolean>
  /** 「启用且未过期」的设备数，用于上限检查 */
  countLiveDevices(): Promise<number>
}

export function createPushApi(deps: PushApiDeps): Hono<{ Variables: SessionVariables }> {
  const app = new Hono<{ Variables: SessionVariables }>()

  app.onError((err, c) => {
    if (err instanceof HTTPException) return err.getResponse()
    console.error('[push-api] 未预期错误：', err)
    return c.json({ code: 500, message: 'internal error' }, 500)
  })

  const requireSession = createRequireSession((headers) => deps.getSession(headers))

  async function readJson(c: { req: { json: () => Promise<unknown> } }): Promise<unknown> {
    try {
      return await c.req.json()
    } catch {
      throw apiError(400, 'invalid_json')
    }
  }

  // -------------------------------------------------------------------------
  // 1. 注册 / 更新设备（App 每次启动都会调，兼当心跳）—— **公开，不需要登录**
  // -------------------------------------------------------------------------
  app.post('/devices', async (c) => {
    const parsed = registerDeviceSchema.safeParse(await readJson(c))
    if (!parsed.success) {
      // 分开报：客户端拿到的是"哪个字段不对"，而不是笼统的 invalid_request
      const field = parsed.error.issues[0]?.path?.[0]
      if (field === 'token') throw apiError(400, 'invalid_token')
      if (field === 'environment') throw apiError(400, 'invalid_environment')
      if (field === 'clientId') throw apiError(400, 'invalid_client_id')
      throw apiError(400, 'invalid_request')
    }

    // 上限只挡「新设备」：已有 token 的心跳必须放行，否则老设备一旦满了就再也续不上
    const known = await deps.deviceExists(parsed.data.token)
    if (!known && (await deps.countLiveDevices()) >= MAX_DEVICES) {
      console.warn(`[push] 设备数已达上限 ${MAX_DEVICES}，拒绝新 token`)
      throw apiError(429, 'too_many_devices')
    }

    const row = await deps.upsertDevice(parsed.data)
    return c.json({ code: 200, message: 'ok', data: toPushDeviceSummary(row) })
  })

  // -------------------------------------------------------------------------
  // 2. 停用设备（用户关掉通知 / 卸载前）—— **公开，靠不可猜的 clientId 定位自己的行**
  // -------------------------------------------------------------------------
  app.delete('/devices', async (c) => {
    const parsed = deviceQuerySchema.safeParse({ clientId: c.req.query('clientId') })
    if (!parsed.success) throw apiError(400, 'invalid_client_id')

    const disabled = await deps.disableDevice({ clientId: parsed.data.clientId })
    return c.json({ code: 200, message: 'ok', data: { disabled } })
  })

  // -------------------------------------------------------------------------
  // 3. 设备列表（诊断：到底注册上了没有、最近什么时候活过）—— 需要登录
  // -------------------------------------------------------------------------
  app.get('/devices', requireSession, async (c) => {
    const [rows, pushEnabled] = await Promise.all([deps.listDevices(), deps.isPushEnabled()])
    return c.json({
      code: 200,
      message: 'ok',
      data: { pushEnabled, devices: rows.map(toPushDeviceSummary) },
    })
  })

  return app
}

/**
 * 设备数上限。
 *
 * 为什么要有：`POST /devices` 是公开接口，没有上限就等于「任何人都能往这张表里灌数据」，
 * 而每次上传照片都会遍历这张表发推送。
 * 为什么是 2000：家庭/朋友共用的量级远不到这个数；到顶了会打 `console.warn`，
 * 真到了就该考虑换成「按安装量配额」的方案，而不是简单加数字。
 */
export const MAX_DEVICES = 2000
