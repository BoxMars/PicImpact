import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { APNS_MAX_PAYLOAD_BYTES, type APNsConfig, type APNsNotification, type APNsResult } from '~/server/lib/apns'
import {
  DEFAULT_COOLDOWN_SECONDS,
  STALE_DEVICE_MS,
  buildNewImagePayload,
  createNewImageNotifier,
  fitPayload,
  isPublicNotice,
  isStaleDevice,
  parseCooldownSeconds,
  type DeliveryLogRow,
  type NewImageNotice,
  type NotifyDeps,
  type PushDeviceRow,
} from '~/server/lib/new-image-notify'

/**
 * 「新照片入库 → 推送」的单测。
 *
 * 全部走 `createNewImageNotifier` 的依赖注入，**不碰数据库、不发真网络**。
 * 覆盖的是那些"错了就会静默失败"的地方：开关、冷却、自己传的不通知自己、
 * 失效 token 的停用、以及"推送失败绝不影响上传"。
 */

const NOW = Date.parse('2026-10-13T12:00:00.000Z')

const APNS: APNsConfig = {
  keyP8: '-----BEGIN PRIVATE KEY-----\\nstub\\n-----END PRIVATE KEY-----',
  keyId: 'ABC123DEFG',
  teamId: 'VX3SCAKB5K',
  bundleId: 'dev.boxz.felina',
}

const NOTICE: NewImageNotice = {
  id: 'clx0000000000000000000001',
  title: '海边日落',
  imageName: 'photo-20261013-120000-abcd.jpg',
  previewUrl: 'https://felina-asset.boxz.dev/images/daily/preview/clx0001.webp',
  albumValue: '/daily',
  show: 0,
  del: 0,
}

function device(overrides: Partial<PushDeviceRow> = {}): PushDeviceRow {
  return {
    id: 'dev_1',
    userId: 'u_1',
    token: 'ab'.repeat(32),
    environment: 'production',
    clientId: 'CLIENT-AAAA-1111',
    enabled: 1,
    lastSeenAt: new Date(NOW - 60_000),
    ...overrides,
  }
}

interface Captured {
  sent: Array<{ notification: APNsNotification; config: APNsConfig }>
  logs: DeliveryLogRow[]
  disabled: string[]
}

function makeDeps(
  options: {
    enabled?: boolean
    cooldownSeconds?: number
    apnsConfig?: APNsConfig | null
    devices?: PushDeviceRow[]
    albumName?: string | null
    lastSentAt?: Record<string, number | null>
    result?: APNsResult
  } = {}
) {
  const captured: Captured = { sent: [], logs: [], disabled: [] }
  const deps: NotifyDeps = {
    now: () => NOW,
    async loadConfig() {
      return {
        enabled: options.enabled ?? true,
        cooldownSeconds: options.cooldownSeconds ?? DEFAULT_COOLDOWN_SECONDS,
        siteTitle: '大福映画 Felina Gallery',
      }
    },
    apnsConfig: () => (options.apnsConfig === undefined ? APNS : options.apnsConfig),
    async listDevices() {
      return options.devices ?? [device()]
    },
    async albumName() {
      return options.albumName === undefined ? '日常' : options.albumName
    },
    async lastSentAt(deviceId) {
      return options.lastSentAt?.[deviceId] ?? null
    },
    async logDelivery(row) {
      captured.logs.push(row)
    },
    async disableDevice(deviceId) {
      captured.disabled.push(deviceId)
    },
    async send(notification, config) {
      captured.sent.push({ notification, config })
      return options.result ?? { ok: true, status: 200, apnsId: 'APNS-ID-1', reason: null, detail: null }
    },
  }
  return { notify: createNewImageNotifier(deps), captured }
}

// ---------------------------------------------------------------------------
// 该不该发
// ---------------------------------------------------------------------------

test('总开关关着：一条都不发，也不记日志', async () => {
  const { notify, captured } = makeDeps({ enabled: false })
  const outcome = await notify(NOTICE)

  assert.equal(outcome.status, 'disabled')
  assert.deepEqual(captured.sent, [])
  assert.deepEqual(captured.logs, [])
})

test('服务端没配 APNs 凭据：静默跳过（这是上线前的默认状态）', async () => {
  const { notify, captured } = makeDeps({ apnsConfig: null })
  const outcome = await notify(NOTICE)

  assert.equal(outcome.status, 'unconfigured')
  assert.deepEqual(captured.sent, [])
})

test('未公开 / 已删除的图不推（通知不能泄露未公开照片）', async () => {
  const { notify, captured } = makeDeps()

  assert.equal((await notify({ ...NOTICE, show: 1 })).status, 'not_public')
  assert.equal((await notify({ ...NOTICE, del: 1 })).status, 'not_public')
  assert.equal((await notify({ ...NOTICE, show: null })).status, 'not_public', '缺省 show 必须当成"不公开"')
  assert.deepEqual(captured.sent, [])
})

test('没有设备可推：明确返回 no_devices，而不是假装成功', async () => {
  const { notify } = makeDeps({ devices: [] })
  assert.equal((await notify(NOTICE)).status, 'no_devices')
})

test('设备已停用 / 已过期（90 天没出现）都不推', async () => {
  const { notify, captured } = makeDeps({
    devices: [
      device({ id: 'dev_disabled', enabled: 0 }),
      device({ id: 'dev_stale', lastSeenAt: new Date(NOW - STALE_DEVICE_MS - 1000) }),
      device({ id: 'dev_ok' }),
    ],
  })

  const outcome = await notify(NOTICE)
  assert.equal(outcome.sent, 1)
  assert.deepEqual(
    captured.sent.map((item) => item.notification.deviceToken),
    ['ab'.repeat(32)]
  )
  assert.equal(captured.logs.length, 1)
  assert.equal(captured.logs[0].deviceId, 'dev_ok')
})

// ---------------------------------------------------------------------------
// 自己传的不通知自己
// ---------------------------------------------------------------------------

test('自己传的不通知自己：clientId 相同的设备被摘掉', async () => {
  const { notify, captured } = makeDeps({
    devices: [device({ id: 'dev_self', clientId: 'SELF-CLIENT-9999' }), device({ id: 'dev_other', clientId: 'OTHER-CLIENT-8888' })],
  })

  const outcome = await notify(NOTICE, { clientId: 'SELF-CLIENT-9999' })
  assert.equal(outcome.sent, 1)
  assert.equal(captured.logs[0].deviceId, 'dev_other')
})

test('网页上传没有 clientId：所有设备都发（这正是主场景）', async () => {
  const { notify, captured } = makeDeps({
    devices: [device({ id: 'dev_1', clientId: 'A-CLIENT-1111' }), device({ id: 'dev_2', clientId: 'B-CLIENT-2222' })],
  })

  const outcome = await notify(NOTICE, { clientId: null })
  assert.equal(outcome.sent, 2)
  assert.equal(captured.sent.length, 2)
})

// ---------------------------------------------------------------------------
// 冷却
// ---------------------------------------------------------------------------

test('冷却期内：跳过且**不写日志**（否则批量上传能把日志表刷爆）', async () => {
  const { notify, captured } = makeDeps({ cooldownSeconds: 120, lastSentAt: { dev_1: NOW - 30_000 } })

  const outcome = await notify(NOTICE)
  assert.equal(outcome.status, 'skipped', '全被冷却挡下 ≠ 发送成功，状态要能区分')
  assert.equal(outcome.skipped, 1)
  assert.equal(outcome.sent, 0)
  assert.deepEqual(captured.sent, [], '冷却期内不该发')
  assert.deepEqual(captured.logs, [], '被冷却挡下不该写日志')
})

test('刚好越过冷却窗口：会发（边界按 >= 处理，不是 >）', async () => {
  const { notify } = makeDeps({ cooldownSeconds: 120, lastSentAt: { dev_1: NOW - 120_000 } })
  const outcome = await notify(NOTICE)
  assert.equal(outcome.sent, 1)
})

test('手动发送：options.body 整句覆盖模板（仍做占位符替换）', async () => {
  const { notify, captured } = makeDeps()
  await notify(NOTICE, { body: '{{album}} 上新：{{title}}' })

  const payload = captured.sent[0].notification.payload as any
  assert.equal(payload.aps.alert.body, '日常 上新：海边日落')
})

test('手动发送：ignoreCooldown 会绕过冷却（人主动点的一次动作）', async () => {
  const { notify, captured } = makeDeps({ cooldownSeconds: 600, lastSentAt: { dev_1: NOW - 1000 } })

  const outcome = await notify(NOTICE, { ignoreCooldown: true })

  assert.equal(outcome.sent, 1, '手动发送不该被冷却挡下')
  assert.equal(captured.sent.length, 1)
})

test('冷却 = 0 表示不冷却', async () => {
  const { notify } = makeDeps({ cooldownSeconds: 0, lastSentAt: { dev_1: NOW } })
  assert.equal((await notify(NOTICE)).sent, 1)
})

// ---------------------------------------------------------------------------
// 失败处理
// ---------------------------------------------------------------------------

test('410 Unregistered：停用设备 + 记 pruned（不物理删，留痕）', async () => {
  const { notify, captured } = makeDeps({
    result: { ok: false, status: 410, apnsId: 'ID', reason: 'Unregistered', detail: null },
  })

  const outcome = await notify(NOTICE)
  assert.equal(outcome.status, 'failed')
  assert.equal(outcome.failed, 1)
  assert.deepEqual(captured.disabled, ['dev_1'])
  assert.equal(captured.logs[0].status, 'pruned')
  assert.equal(captured.logs[0].reason, 'Unregistered')
})

test('BadDeviceToken 同样按失效处理', async () => {
  const { notify, captured } = makeDeps({
    result: { ok: false, status: 400, apnsId: 'ID', reason: 'BadDeviceToken', detail: null },
  })

  await notify(NOTICE)
  assert.deepEqual(captured.disabled, ['dev_1'])
  assert.equal(captured.logs[0].status, 'pruned')
})

test('其它失败（网络/超时/服务端 5xx）：记 failed 但**不停用**设备', async () => {
  const { notify, captured } = makeDeps({
    result: { ok: false, status: null, apnsId: null, reason: 'Timeout', detail: '2500ms' },
  })

  await notify(NOTICE)
  assert.deepEqual(captured.disabled, [], '一次超时不能把设备停掉')
  assert.equal(captured.logs[0].status, 'failed')
  assert.equal(captured.logs[0].httpStatus, null)
})

// ---------------------------------------------------------------------------
// 载荷
// ---------------------------------------------------------------------------

test('载荷：只有标题 + 正文（相册名不再作副标题），且带 imageId 供点击跳转', async () => {
  const { notify, captured } = makeDeps()
  await notify(NOTICE)

  const payload = captured.sent[0].notification.payload as any
  assert.equal(payload.aps.alert.title, '大福映画 Felina Gallery')
  assert.equal('subtitle' in payload.aps.alert, false, '相册名不再占副标题位（用户要求）')
  assert.equal(payload.aps.alert.body, '「海边日落」刚刚上传', '默认模板渲染')
  assert.equal(payload.aps['thread-id'], 'new-images')
  assert.equal(payload.aps.sound, 'default')
  assert.equal(payload.v, 1)
  assert.equal(payload.imageId, NOTICE.id)
  assert.equal(payload.albumValue, '/daily')

  const notification = captured.sent[0].notification
  assert.equal(notification.pushType, 'alert')
  assert.equal(notification.priority, 10)
  assert.equal(notification.collapseId, 'new-images')
  assert.equal(notification.environment, 'production')
})

test('载荷：没有标题时用文件名；都没有时给一句兜底文案', async () => {
  const { notify, captured } = makeDeps()

  await notify({ ...NOTICE, title: '' })
  assert.equal((captured.sent.at(-1)!.notification.payload as any).aps.alert.body, '「photo-20261013-120000-abcd.jpg」刚刚上传')

  await notify({ ...NOTICE, title: '', imageName: '' })
  assert.equal((captured.sent.at(-1)!.notification.payload as any).aps.alert.body, '「一张新照片」刚刚上传')
})

test('载荷：相册名仍然会作为 {{album}} 的取值（想显示就写进模板）', () => {
  const withAlbum = buildNewImagePayload(NOTICE, {
    siteTitle: 'T',
    albumName: '日常',
    bodyTemplate: '{{album}} 有新照片：{{title}}',
  }) as any
  assert.equal(withAlbum.aps.alert.body, '日常 有新照片：海边日落')
  assert.equal('subtitle' in withAlbum.aps.alert, false, '副标题永远不发，避免和正文重复')
})

test('载荷：极端长标题也压得进 4 KB（超限 APNs 是直接拒，不是截断）', () => {
  const payload = buildNewImagePayload(
    { ...NOTICE, title: '很长的标题'.repeat(2000), imageName: 'x'.repeat(200) },
    { siteTitle: '大福映画 Felina Gallery', albumName: '日常'.repeat(50) }
  )
  const bytes = new TextEncoder().encode(JSON.stringify(payload)).length

  assert.ok(bytes <= APNS_MAX_PAYLOAD_BYTES, `载荷 ${bytes} 字节，超过 ${APNS_MAX_PAYLOAD_BYTES}`)
  assert.ok((payload as any).aps.alert.body.length > 0, '截断后仍要有正文')
})

test('fitPayload：先丢预览图，再折半正文；本来就够小则原样返回', () => {
  const small = { aps: { alert: { body: 'hi' } }, previewUrl: 'https://x/y.webp' }
  assert.equal(fitPayload(small), small, '够小的时候不该改动对象')

  const big = fitPayload(
    { aps: { alert: { body: 'x'.repeat(9000) } }, previewUrl: 'https://x/y.webp' },
    512
  ) as any
  assert.equal('previewUrl' in big, false, '先丢预览图 URL')
  assert.ok(new TextEncoder().encode(JSON.stringify(big)).length <= 512)
})

// ---------------------------------------------------------------------------
// 纯函数
// ---------------------------------------------------------------------------

test('parseCooldownSeconds：非法值回落到默认，超大值夹到一天', () => {
  assert.equal(parseCooldownSeconds('120'), 120)
  assert.equal(parseCooldownSeconds('0'), 0)
  assert.equal(parseCooldownSeconds('abc'), DEFAULT_COOLDOWN_SECONDS)
  assert.equal(parseCooldownSeconds(''), DEFAULT_COOLDOWN_SECONDS)
  assert.equal(parseCooldownSeconds('-5'), DEFAULT_COOLDOWN_SECONDS)
  assert.equal(parseCooldownSeconds('99999999'), 86_400)
})

test('isPublicNotice：show/del 必须显式为 0', () => {
  assert.equal(isPublicNotice({ id: 'x', show: 0, del: 0 }), true)
  assert.equal(isPublicNotice({ id: 'x', show: 0 }), false, 'del 缺省视为不安全')
  assert.equal(isPublicNotice({ id: 'x', show: 1, del: 0 }), false)
})

test('isStaleDevice：null / 非法时间都当过期，正好 90 天不过期', () => {
  assert.equal(isStaleDevice(null, NOW), true)
  assert.equal(isStaleDevice('not-a-date', NOW), true)
  assert.equal(isStaleDevice(new Date(NOW - STALE_DEVICE_MS), NOW), false)
  assert.equal(isStaleDevice(new Date(NOW - STALE_DEVICE_MS - 1), NOW), true)
  assert.equal(isStaleDevice(new Date(NOW - 1000).toISOString(), NOW), false)
})

test('环境：sandbox 设备走 sandbox，其余一律 production（不能把沙箱 token 打到生产）', async () => {
  const { notify, captured } = makeDeps({
    devices: [device({ id: 'd1', environment: 'sandbox' }), device({ id: 'd2', environment: 'production' }), device({ id: 'd3', environment: 'weird' })],
  })
  await notify(NOTICE)

  assert.deepEqual(
    captured.sent.map((item) => item.notification.environment),
    ['sandbox', 'production', 'production']
  )
})

// ---------------------------------------------------------------------------
// 结构性：两个入口都必须接上推送
// ---------------------------------------------------------------------------

test('结构性：两个写图片入口都必须调用 notifyNewImage（防"新增入口忘了接线"）', () => {
  // App 登记走 hono/admin/api.ts 的工厂（真实实现在 hono/admin/index.ts 注入）；
  // Web 上传走 hono/images.ts。
  const entryPoints = ['hono/images.ts', 'hono/admin/api.ts']

  for (const file of entryPoints) {
    const source = readFileSync(file, 'utf8')
    assert.match(source, /notifyNewImage/, `${file} 没有接上 notifyNewImage —— 从它进来的新照片不会推送`)
  }

  // 装配层要真的把真实实现注入进去，而不是留一个空壳
  assert.match(readFileSync('hono/admin/index.ts', 'utf8'), /notifyNewImage/, 'hono/admin/index.ts 没注入真实实现')
})
