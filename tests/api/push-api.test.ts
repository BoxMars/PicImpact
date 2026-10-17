import assert from 'node:assert/strict'
import { test } from 'node:test'

import { Hono } from 'hono'

import { MAX_DEVICES, createPushApi, type PushApiDeps, type PushSession } from '~/hono/push/api'
import { toPushDeviceSummary } from '~/server/lib/push-api'

/**
 * `/api/v1/push/*` 的单测。
 *
 * 重点钉住 2026-10-17 纠正后的语义：
 *   · **注册与停用是公开的**（装了 App 就能收通知，不需要登录）
 *   · **只有设备列表需要登录**（诊断入口）
 *   · 公开写入有三道闸：字段校验、token 去重、设备上限
 */

const SESSION: PushSession = { userId: 'user_1', email: 'me@boxz.dev' }

const TOKEN = 'ab'.repeat(32)
const CLIENT_ID = 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890'

function json(body: unknown): RequestInit {
  return {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }
}

interface Captured {
  upserted: Array<Record<string, any>>
  disabled: Array<{ clientId: string }>
  listCalls: number
  isPushEnabledCalls: number
  existsChecks: string[]
  liveCountCalls: number
  sentPush: { notice: Record<string, any>; body?: string | null } | null
}

function makeDeps(
  options: {
    session?: PushSession | null
    pushEnabled?: boolean
    rows?: Record<string, any>[]
    deviceExists?: boolean
    liveDevices?: number
    imageFound?: boolean
  } = {}
) {
  const captured: Captured = {
    upserted: [],
    disabled: [],
    listCalls: 0,
    isPushEnabledCalls: 0,
    existsChecks: [],
    liveCountCalls: 0,
    sentPush: null,
  }

  const deps: PushApiDeps = {
    async getSession() {
      return options.session === undefined ? SESSION : options.session
    },
    async upsertDevice(input) {
      captured.upserted.push(input)
      return {
        id: 'dev_1',
        token: input.token,
        environment: input.environment,
        bundleId: 'dev.boxz.felina',
        clientId: input.clientId,
        deviceName: input.deviceName ?? null,
        systemVersion: input.systemVersion ?? null,
        appVersion: input.appVersion ?? null,
        locale: input.locale ?? null,
        enabled: 1,
        lastSeenAt: new Date('2026-10-17T12:00:00.000Z'),
      }
    },
    async disableDevice(input) {
      captured.disabled.push(input)
      return 1
    },
    async listDevices() {
      captured.listCalls += 1
      return (
        options.rows ?? [
          {
            id: 'dev_1',
            token: TOKEN,
            environment: 'production',
            clientId: CLIENT_ID,
            deviceName: 'iPhone 16 Pro',
            systemVersion: '26.0',
            appVersion: '1.0',
            enabled: 1,
            lastSeenAt: new Date('2026-10-17T12:00:00.000Z'),
          },
        ]
      )
    },
    async isPushEnabled() {
      captured.isPushEnabledCalls += 1
      return options.pushEnabled ?? true
    },
    async deviceExists(token) {
      captured.existsChecks.push(token)
      return options.deviceExists ?? false
    },
    async countLiveDevices() {
      captured.liveCountCalls += 1
      return options.liveDevices ?? 0
    },
    async loadImageForPush(imageId) {
      if (options.imageFound === false) return null
      return {
        id: imageId,
        title: '海边日落',
        imageName: 'photo-20261017.jpg',
        previewUrl: 'https://felina-asset.boxz.dev/images/daily/preview/x.webp',
        albumValue: '/daily',
        show: 0,
        del: 0,
      }
    },
    async sendPushNow(notice, sendOptions) {
      captured.sentPush = { notice: notice as Record<string, any>, body: sendOptions.body }
      return { status: 'sent', sent: 2, skipped: 0, failed: 0 }
    },
  }

  return { api: createPushApi(deps), captured }
}

// ---------------------------------------------------------------------------
// 公开注册（2026-10-17 纠正：不再需要登录）
// ---------------------------------------------------------------------------

test('注册不需要登录：没有会话也能注册成功', async () => {
  const { api, captured } = makeDeps({ session: null })

  const res = await api.request(
    '/devices',
    json({ token: TOKEN, environment: 'production', clientId: CLIENT_ID, deviceName: '朋友的 iPhone' })
  )

  assert.equal(res.status, 200)
  const payload = await res.json()
  assert.equal(payload.data.enabled, 1)
  assert.equal(payload.data.tokenSuffix, TOKEN.slice(-8))
  assert.equal(JSON.stringify(payload).includes(TOKEN), false, '响应里不得出现完整 device token')

  assert.equal(captured.upserted.length, 1)
  assert.equal(captured.upserted[0].clientId, CLIENT_ID)
  assert.equal('userId' in captured.upserted[0], false, '设备与账号无关，不该再写 userId')
  assert.equal('bundleId' in captured.upserted[0], false, 'bundleId 由装配层补，路由不该透传')
})

test('注册：body 里塞 userId / bundleId 一律无效（zod 丢掉未声明字段）', async () => {
  const { api, captured } = makeDeps()

  const res = await api.request(
    '/devices',
    json({ token: TOKEN, environment: 'production', clientId: CLIENT_ID, userId: 'attacker', bundleId: 'com.evil.app' })
  )

  assert.equal(res.status, 200)
  assert.equal('userId' in captured.upserted[0], false)
  assert.equal('bundleId' in captured.upserted[0], false)
})

test('注册：字段非法分开报', async () => {
  const { api, captured } = makeDeps()
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ token: 'not-hex', environment: 'production', clientId: CLIENT_ID }, 'invalid_token'],
    [{ token: TOKEN, environment: 'staging', clientId: CLIENT_ID }, 'invalid_environment'],
    [{ token: TOKEN, environment: 'production', clientId: 'x' }, 'invalid_client_id'],
  ]

  for (const [body, expected] of cases) {
    const res = await api.request('/devices', json(body))
    assert.equal(res.status, 400)
    assert.deepEqual(await res.json(), { code: 400, message: expected })
  }

  const broken = await api.request('/devices', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{not json',
  })
  assert.equal(broken.status, 400)
  assert.deepEqual(await broken.json(), { code: 400, message: 'invalid_json' })

  assert.deepEqual(captured.upserted, [], '校验失败不得入库')
})

// ---------------------------------------------------------------------------
// 设备上限（公开接口的唯一一道量级闸）
// ---------------------------------------------------------------------------

test('上限：设备数已满且是新 token → 429', async () => {
  const { api, captured } = makeDeps({ deviceExists: false, liveDevices: MAX_DEVICES })

  const res = await api.request('/devices', json({ token: TOKEN, environment: 'production', clientId: CLIENT_ID }))

  assert.equal(res.status, 429)
  assert.deepEqual(await res.json(), { code: 429, message: 'too_many_devices' })
  assert.equal(captured.liveCountCalls, 1)
  assert.deepEqual(captured.upserted, [], '超限时不该写库')
})

test('上限：已注册过的 token（心跳）在满额时也要放行，否则老设备会被挤掉', async () => {
  const { api, captured } = makeDeps({ deviceExists: true, liveDevices: MAX_DEVICES })

  const res = await api.request('/devices', json({ token: TOKEN, environment: 'production', clientId: CLIENT_ID }))

  assert.equal(res.status, 200)
  assert.equal(captured.upserted.length, 1)
})

test('上限：没满时正常注册', async () => {
  const { api, captured } = makeDeps({ deviceExists: false, liveDevices: MAX_DEVICES - 1 })

  const res = await api.request('/devices', json({ token: TOKEN, environment: 'production', clientId: CLIENT_ID }))
  assert.equal(res.status, 200)
  assert.equal(captured.liveCountCalls, 1)
})

// ---------------------------------------------------------------------------
// 停用（公开）
// ---------------------------------------------------------------------------

test('停用不需要登录：按 clientId 置 enabled=0', async () => {
  const { api, captured } = makeDeps({ session: null })

  const res = await api.request(`/devices?clientId=${CLIENT_ID}`, { method: 'DELETE' })

  assert.equal(res.status, 200)
  assert.deepEqual(await res.json(), { code: 200, message: 'ok', data: { disabled: 1 } })
  assert.deepEqual(captured.disabled, [{ clientId: CLIENT_ID }])
})

test('停用：缺 clientId 或形状不对 → 400', async () => {
  const { api, captured } = makeDeps()

  for (const url of ['/devices', '/devices?clientId=', '/devices?clientId=bad id']) {
    const res = await api.request(url, { method: 'DELETE' })
    assert.equal(res.status, 400, `${url} 应当 400`)
    assert.deepEqual(await res.json(), { code: 400, message: 'invalid_client_id' })
  }
  assert.deepEqual(captured.disabled, [])
})

// ---------------------------------------------------------------------------
// 对指定照片发通知（需要登录）
// ---------------------------------------------------------------------------

const SEND_BODY = { imageId: 'clx0000000000000000000001' }

test('发通知：未登录 401，且不会真的发', async () => {
  const { api, captured } = makeDeps({ session: null })

  const res = await api.request('/send', json(SEND_BODY))

  assert.equal(res.status, 401)
  assert.equal(captured.sentPush, null)
})

test('发通知：图片不存在 → 404', async () => {
  const { api, captured } = makeDeps({ imageFound: false })

  const res = await api.request('/send', json(SEND_BODY))

  assert.equal(res.status, 404)
  assert.deepEqual(await res.json(), { code: 404, message: 'image_not_found' })
  assert.equal(captured.sentPush, null)
})

test('发通知：正常发送，回传 sent/failed 统计；正文透传', async () => {
  const { api, captured } = makeDeps()

  const res = await api.request('/send', json({ ...SEND_BODY, body: '{{album}} 上新' }))

  assert.equal(res.status, 200)
  const payload = await res.json()
  assert.deepEqual(payload.data, { status: 'sent', sent: 2, skipped: 0, failed: 0 })
  assert.equal(captured.sentPush?.notice.id, SEND_BODY.imageId)
  assert.equal(captured.sentPush?.body, '{{album}} 上新', '正文原样交给模板渲染，不在这一层替换')
})

test('发通知：imageId 形状非法 → 400；不带 body 也能发（用模板）', async () => {
  const { api, captured } = makeDeps()

  const bad = await api.request('/send', json({ imageId: '../../etc/passwd' }))
  assert.equal(bad.status, 400)

  const ok = await api.request('/send', json(SEND_BODY))
  assert.equal(ok.status, 200)
  assert.equal(captured.sentPush?.body, null)
})

// ---------------------------------------------------------------------------
// 设备列表（仍然需要登录）
// ---------------------------------------------------------------------------

test('列表：未登录 401，且不碰任何依赖', async () => {
  const { api, captured } = makeDeps({ session: null })

  const res = await api.request('/devices')

  assert.equal(res.status, 401)
  assert.deepEqual(await res.json(), { code: 401, message: 'authentication failed' })
  assert.equal(captured.listCalls, 0)
  assert.equal(captured.isPushEnabledCalls, 0)
})

test('列表：登录后返回**所有**设备（不再按用户过滤）+ pushEnabled', async () => {
  const { api, captured } = makeDeps({
    rows: [
      { id: 'd1', token: 'aa'.repeat(32), environment: 'production', clientId: 'C1-AAAA-1111', enabled: 1, lastSeenAt: null },
      { id: 'd2', token: 'bb'.repeat(32), environment: 'sandbox', clientId: 'C2-BBBB-2222', enabled: 0, lastSeenAt: null },
    ],
  })

  const payload = await (await api.request('/devices')).json()

  assert.equal(captured.listCalls, 1)
  assert.equal(payload.data.pushEnabled, true)
  assert.equal(payload.data.devices.length, 2, '诊断要看全部设备，包括已停用的')
  assert.equal(JSON.stringify(payload).includes('aa'.repeat(32)), false, '不得回显完整 token')
})

// ---------------------------------------------------------------------------
// 纯函数
// ---------------------------------------------------------------------------

test('toPushDeviceSummary：字段缺失/异构类型不炸，token 短于 8 位时原样返回', () => {
  const summary = toPushDeviceSummary({ id: 'x', token: 'abc', enabled: undefined, lastSeenAt: null })
  assert.equal(summary.tokenSuffix, 'abc')
  assert.equal(summary.enabled, 0)
  assert.equal(summary.deviceName, null)
  assert.equal(summary.lastSeenAt, null)

  const fromDate = toPushDeviceSummary({ id: 'y', token: TOKEN, lastSeenAt: new Date('2026-01-02T03:04:05.000Z') })
  assert.equal(fromDate.lastSeenAt, '2026-01-02T03:04:05.000Z')

  const fromString = toPushDeviceSummary({ id: 'z', token: TOKEN, lastSeenAt: '2026-01-02T03:04:05.000Z' })
  assert.equal(fromString.lastSeenAt, '2026-01-02T03:04:05.000Z')
})

test('路由挂在 /api/v1/push 下时路径前缀正确（Hono 子应用不自带前缀）', async () => {
  const { api } = makeDeps()
  const mounted = new Hono().basePath('/api').route('/v1/push', api)

  const res = await mounted.request('/api/v1/push/devices')
  assert.equal(res.status, 200, '登录状态下 GET 应当放行')
  assert.equal((await mounted.request('/api/v1/devices')).status, 404)
})
