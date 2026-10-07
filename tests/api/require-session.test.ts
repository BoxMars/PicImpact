import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'

import { Hono } from 'hono'

import { UNAUTHENTICATED_BODY, createRequireSession, type SessionLookup } from '~/hono/require-session'

/**
 * 鉴权绕过修复的回归测试（2026-10-07）。
 *
 * 背景：`proxy.ts` 的 `getSessionCookie()` 只判断 cookie 在不在（不验签、不查库），
 * 而 `/api/v1/*` 下的写接口路由内也不再校验 —— 于是伪造一个 cookie 名+假值就能改生产数据。
 * 修法是把真正的校验抽成 `hono/require-session.ts` 的中间件，所有 `/api/v1` 子路由都挂上。
 *
 * 这组测试盯两件事：
 * 1. 中间件本身的行为（没会话 401 且**不进** handler、有会话放行）；
 * 2. **结构性防回归**：hono/ 下每个注册了路由的文件都必须挂着这套校验 ——
 *    将来谁新加一个写接口文件却忘了挂，这里会直接失败。
 */

// ---------------------------------------------------------------------------
// 1. 中间件行为
// ---------------------------------------------------------------------------

test('没有会话：401，且下游 handler 完全不执行（不可能产生数据变更）', async () => {
  let handlerCalls = 0
  const app = new Hono()
  app.use('*', createRequireSession(async () => null))
  app.post('/write', (c) => {
    handlerCalls += 1
    return c.json({ ok: true })
  })
  app.delete('/write/:id', (c) => {
    handlerCalls += 1
    return c.json({ ok: true })
  })

  for (const [path, method] of [
    ['/write', 'POST'],
    ['/write/abc', 'DELETE'],
  ] as const) {
    const res = await app.request(path, { method })
    assert.equal(res.status, 401, `${method} ${path}`)
    assert.deepEqual(await res.json(), UNAUTHENTICATED_BODY)
  }
  assert.equal(handlerCalls, 0, '被拒的请求绝不能进到业务逻辑')
})

test('有效会话：放行（这是"别把用户锁在后台外面"的那一半）', async () => {
  const app = new Hono()
  app.use('*', createRequireSession(async () => ({ userId: 'u_1', email: 'admin@example.com' })))
  app.post('/write', (c) => c.json({ ok: true }))

  const res = await app.request('/write', { method: 'POST' })
  assert.equal(res.status, 200)
  assert.deepEqual(await res.json(), { ok: true })
})

test('判据是"会话是否真的有效"，不是"cookie 在不在"', async () => {
  // 替身模拟真实情形：cookie 里带了一个伪造值 → better-auth 查不到会话 → 必须 401
  const forged: SessionLookup = async (headers) => {
    const cookie = headers.get('cookie') ?? ''
    return cookie.includes('forged') ? null : { userId: 'u_1', email: 'admin@example.com' }
  }
  const app = new Hono()
  app.use('*', createRequireSession(forged))
  app.post('/write', (c) => c.json({ ok: true }))

  const bad = await app.request('/write', {
    method: 'POST',
    headers: { cookie: 'pic-impact.session_token=forged.signature' },
  })
  assert.equal(bad.status, 401)

  const good = await app.request('/write', {
    method: 'POST',
    headers: { cookie: 'pic-impact.session_token=real.signed' },
  })
  assert.equal(good.status, 200)
})

// ---------------------------------------------------------------------------
// 2. 结构性防回归：hono/ 下每个注册路由的文件都必须挂校验
// ---------------------------------------------------------------------------

/** 匿名可访问的路由（对外只读 API），它们**不应该**要求会话 */
const ANONYMOUS_BY_DESIGN = [join('hono', 'open'), join('hono', 'public-api')]

function routeFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) return routeFiles(full)
    return entry.endsWith('.ts') ? [full] : []
  })
}

test('hono/ 下每个注册了路由的文件都挂了会话校验（防"新加接口忘挂"）', () => {
  const files = routeFiles('hono')
  const checked: string[] = []
  const offenders: string[] = []

  for (const file of files) {
    if (ANONYMOUS_BY_DESIGN.some((prefix) => file.startsWith(prefix))) continue
    const source = readFileSync(file, 'utf8')
    // 只看"真的注册了路由"的文件（index.ts 这类只是聚合，没有自己的端点）
    if (!/app\.(get|post|put|delete|patch)\(/.test(source)) continue
    checked.push(file)
    if (!/requireSession|createRequireSession/.test(source)) offenders.push(file)
  }

  assert.ok(checked.length >= 6, `扫描到的路由文件太少（${checked.length}），测试本身可能失效了`)
  assert.deepEqual(offenders, [], `这些文件注册了路由却没挂会话校验：${offenders.join(', ')}`)
})

test('脚本自身已覆盖 /api/v1 下所有写接口所在文件', () => {
  // 显式点名，避免"扫描逻辑写错导致漏扫"时测试反而变绿
  const mustBeChecked = [
    'hono/images.ts',
    'hono/albums.ts',
    'hono/settings.ts',
    'hono/file.ts',
    'hono/storage/open-list.ts',
    'hono/admin/api.ts',
  ]
  const scanned = routeFiles('hono').filter((f) => !ANONYMOUS_BY_DESIGN.some((p) => f.startsWith(p)))
  for (const file of mustBeChecked) {
    assert.ok(scanned.includes(file), `${file} 没被扫描到`)
    assert.match(readFileSync(file, 'utf8'), /requireSession|createRequireSession/, `${file} 没挂校验`)
  }
})
