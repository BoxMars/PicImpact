import assert from 'node:assert/strict'
import { generateKeyPairSync, verify as verifySignature } from 'node:crypto'
import { readFileSync } from 'node:fs'
import http2 from 'node:http2'
import type { IncomingHttpHeaders } from 'node:http2'
import { after, test } from 'node:test'

import {
  APNS_MAX_PAYLOAD_BYTES,
  buildAPNsHeaders,
  interpretAPNsResponse,
  isAPNsConfigured,
  isValidDeviceToken,
  readAPNsConfigFromEnv,
  resetAPNsCachesForTest,
  selectCredentials,
  sendPush,
  signProviderToken,
  type APNsConfig,
} from '~/server/lib/apns'

/**
 * APNs 客户端的单测。
 *
 * 分三层：
 * 1. **纯函数**：JWT 签名（用真实 EC 密钥对**验签**，不是只看字符串形状）、header 组装、响应解释、配置读取；
 * 2. **真连接**：起一个本地明文 HTTP/2（h2c）服务冒充 APNs，把请求头/路径/载荷/状态码处理整条路径跑通；
 * 3. **结构性**：这个文件里不许出现 `fetch(` —— 见文件头注释，fetch 到 APNs 是实测打不通的。
 */

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
const P8 = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()

const BASE_CONFIG: APNsConfig = {
  keyP8: P8,
  keyId: 'ABC123DEFG',
  teamId: 'VX3SCAKB5K',
  bundleId: 'dev.boxz.felina',
}

after(() => resetAPNsCachesForTest())

// ---------------------------------------------------------------------------
// 1. 纯函数
// ---------------------------------------------------------------------------

test('provider token：ES256 + kid/iss/iat，且能用公钥验签通过', () => {
  const token = signProviderToken({
    keyId: 'ABC123DEFG',
    teamId: 'VX3SCAKB5K',
    p8: P8,
    issuedAtSeconds: 1_760_000_000,
  })

  const [headerPart, claimsPart, signaturePart] = token.split('.')
  assert.equal(token.split('.').length, 3, 'JWT 必须三段')

  const header = JSON.parse(Buffer.from(headerPart, 'base64url').toString('utf8'))
  assert.deepEqual(header, { alg: 'ES256', kid: 'ABC123DEFG' })

  const claims = JSON.parse(Buffer.from(claimsPart, 'base64url').toString('utf8'))
  assert.deepEqual(claims, { iss: 'VX3SCAKB5K', iat: 1_760_000_000 })

  // 关键：签名必须是 JOSE 要的裸 r||s（64 字节），不是 DER。
  // 用默认 dsaEncoding 签出来的 DER 签名长度不固定，这里会直接被这条断言拦住。
  const signature = Buffer.from(signaturePart, 'base64url')
  assert.equal(signature.length, 64, 'ES256 的签名必须是 64 字节裸 r||s，DER 编码是错的')

  const verified = verifySignature(
    'sha256',
    Buffer.from(`${headerPart}.${claimsPart}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    signature
  )
  assert.equal(verified, true, 'token 必须能用对应公钥验签通过')
})

test('device token 校验：接受十六进制，拒绝空串/非十六进制/超长', () => {
  assert.equal(isValidDeviceToken('a'.repeat(64)), true)
  assert.equal(isValidDeviceToken('0123456789abcdef'.repeat(4)), true)
  assert.equal(isValidDeviceToken(''), false)
  assert.equal(isValidDeviceToken('z'.repeat(64)), false)
  assert.equal(isValidDeviceToken('a'.repeat(31)), false)
  assert.equal(isValidDeviceToken('a'.repeat(201)), false)
  assert.equal(isValidDeviceToken('  ' + 'a'.repeat(64)), false, '带空格必须被拒（token 会进 URL path）')
})

test('凭据选择：沙箱配了专用 key 就用它，没配就复用生产的', () => {
  assert.deepEqual(selectCredentials(BASE_CONFIG, 'production'), {
    keyId: 'ABC123DEFG',
    keyP8: P8,
  })
  assert.deepEqual(selectCredentials(BASE_CONFIG, 'sandbox'), {
    keyId: 'ABC123DEFG',
    keyP8: P8,
  })

  const withSandbox = { ...BASE_CONFIG, sandboxKeyP8: P8, sandboxKeyId: 'ZZZ999YYY' }
  assert.equal(selectCredentials(withSandbox, 'sandbox').keyId, 'ZZZ999YYY')
  assert.equal(selectCredentials(withSandbox, 'production').keyId, 'ABC123DEFG')
})

test('isAPNsConfigured：缺任何一项都算没配好', () => {
  assert.equal(isAPNsConfigured(BASE_CONFIG), true)
  assert.equal(isAPNsConfigured(null), false)
  assert.equal(isAPNsConfigured({ ...BASE_CONFIG, keyP8: '' }), false)
  assert.equal(isAPNsConfigured({ ...BASE_CONFIG, keyId: '' }), false)
  assert.equal(isAPNsConfigured({ ...BASE_CONFIG, teamId: '' }), false)
  assert.equal(isAPNsConfigured({ ...BASE_CONFIG, bundleId: '' }), false)
})

test('请求头：topic 用 bundle id，path 带 device token，alert 默认 priority 10', () => {
  const headers = buildAPNsHeaders(
    { deviceToken: 'ab'.repeat(32), environment: 'production', payload: { aps: {} } },
    { bundleId: 'dev.boxz.felina', providerToken: 'TOKEN', apnsId: 'APNS-ID', nowMs: 1_760_000_000_000 }
  )

  assert.equal(headers[':method'], 'POST')
  assert.equal(headers[':path'], `/3/device/${'ab'.repeat(32)}`)
  assert.equal(headers['apns-topic'], 'dev.boxz.felina')
  assert.equal(headers['apns-push-type'], 'alert')
  assert.equal(headers['apns-priority'], '10')
  assert.equal(headers.authorization, 'bearer TOKEN')
  assert.equal(headers['apns-id'], 'APNS-ID')
  assert.equal(headers['apns-expiration'], undefined, '不传有效期就交给 APNs 的默认存储策略')
})

test('请求头：background 必须是 priority 5，写了 10 也会被纠正（官方说 10 是错误）', () => {
  const headers = buildAPNsHeaders(
    {
      deviceToken: 'ab'.repeat(32),
      environment: 'production',
      payload: { aps: { 'content-available': 1 } },
      pushType: 'background',
      priority: 10,
    },
    { bundleId: 'dev.boxz.felina', providerToken: 'TOKEN', apnsId: 'ID', nowMs: 0 }
  )
  assert.equal(headers['apns-push-type'], 'background')
  assert.equal(headers['apns-priority'], '5')
})

test('请求头：有效期是绝对时间戳；collapse-id 超 64 字节被截断', () => {
  const headers = buildAPNsHeaders(
    {
      deviceToken: 'ab'.repeat(32),
      environment: 'production',
      payload: { aps: {} },
      expirationSeconds: 3600,
      collapseId: 'x'.repeat(100),
    },
    { bundleId: 'dev.boxz.felina', providerToken: 'T', apnsId: 'I', nowMs: 1_000_000 }
  )
  assert.equal(headers['apns-expiration'], String(1000 + 3600))
  assert.equal(headers['apns-collapse-id'].length, 64)
})

test('响应解释：200 成功；错误解析出 reason；非 JSON 原文进 detail', () => {
  assert.deepEqual(interpretAPNsResponse(200, '', 'ID'), {
    ok: true,
    status: 200,
    apnsId: 'ID',
    reason: null,
    detail: null,
  })

  const bad = interpretAPNsResponse(410, '{"reason":"Unregistered"}', 'ID')
  assert.equal(bad.ok, false)
  assert.equal(bad.status, 410)
  assert.equal(bad.reason, 'Unregistered')

  const weird = interpretAPNsResponse(500, '<html>oops</html>', 'ID')
  assert.equal(weird.reason, null)
  assert.equal(weird.detail, '<html>oops</html>')
})

test('读环境变量：.p8 的 \\n 要还原成真换行；缺项返回 null', () => {
  const config = readAPNsConfigFromEnv({
    APNS_KEY_P8: '-----BEGIN PRIVATE KEY-----\\nABC\\n-----END PRIVATE KEY-----',
    APNS_KEY_ID: 'ABC123DEFG',
    APNS_TEAM_ID: 'VX3SCAKB5K',
  })
  assert.ok(config)
  assert.equal(config.keyP8.includes('\n'), true, '\\n 必须还原成真换行，否则 PEM 解析失败')
  assert.equal(config.bundleId, 'dev.boxz.felina', 'bundle id 有默认值')

  assert.equal(readAPNsConfigFromEnv({ APNS_KEY_ID: 'X' }), null)
  assert.equal(readAPNsConfigFromEnv({}), null)
})

// ---------------------------------------------------------------------------
// 2. 真连接（本地明文 HTTP/2 冒充 APNs）
// ---------------------------------------------------------------------------

interface CapturedRequest {
  path: string
  method: string
  headers: IncomingHttpHeaders
  body: string
}

async function withFakeAPNs(
  respond: (index: number, request: CapturedRequest) => { status: number; body?: string },
  run: (origin: string, captured: CapturedRequest[]) => Promise<void>
): Promise<void> {
  const captured: CapturedRequest[] = []
  const server = http2.createServer()
  server.on('stream', (stream, headers) => {
    const chunks: Buffer[] = []
    stream.on('data', (chunk: Buffer) => chunks.push(chunk))
    stream.on('end', () => {
      const request: CapturedRequest = {
        path: String(headers[':path']),
        method: String(headers[':method']),
        headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }
      captured.push(request)
      const { status, body } = respond(captured.length - 1, request)
      stream.respond({ ':status': status })
      stream.end(body ?? '')
    })
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const port = typeof address === 'object' && address ? address.port : 0
  resetAPNsCachesForTest()
  try {
    await run(`http://127.0.0.1:${port}`, captured)
  } finally {
    // 强制收掉客户端连接，否则 server.close() 会一直等
    resetAPNsCachesForTest()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
}

function configFor(origin: string): APNsConfig {
  return { ...BASE_CONFIG, endpoints: { sandbox: origin, production: origin } }
}

const NOTIFICATION = {
  deviceToken: 'ab'.repeat(32),
  environment: 'production' as const,
  payload: {
    aps: { alert: { title: '大福映画', body: '「海边日落」刚刚上传' }, 'thread-id': 'new-images' },
    v: 1,
    imageId: 'clx123',
  },
  collapseId: 'new-images',
  expirationSeconds: 3600,
}

test('真发一条：请求头与载荷正确，200 判定为成功', async () => {
  await withFakeAPNs(
    () => ({ status: 200 }),
    async (origin, captured) => {
      const result = await sendPush(NOTIFICATION, configFor(origin))

      assert.equal(result.ok, true)
      assert.equal(result.status, 200)
      assert.ok(result.apnsId, 'apns-id 必须回传，便于排障')

      assert.equal(captured.length, 1)
      const request = captured[0]
      assert.equal(request.method, 'POST')
      assert.equal(request.path, `/3/device/${'ab'.repeat(32)}`)
      assert.equal(request.headers['apns-topic'], 'dev.boxz.felina')
      assert.equal(request.headers['apns-push-type'], 'alert')
      assert.equal(request.headers['apns-priority'], '10')
      assert.equal(request.headers['apns-collapse-id'], 'new-images')
      assert.match(String(request.headers.authorization), /^bearer ey/)

      const payload = JSON.parse(request.body)
      assert.equal(payload.imageId, 'clx123')
      assert.equal(payload.aps['thread-id'], 'new-images')
    }
  )
})

test('真发一条：410 Unregistered 被解释成可据此停用设备的失败', async () => {
  await withFakeAPNs(
    () => ({ status: 410, body: '{"reason":"Unregistered"}' }),
    async (origin) => {
      const result = await sendPush(NOTIFICATION, configFor(origin))
      assert.equal(result.ok, false)
      assert.equal(result.status, 410)
      assert.equal(result.reason, 'Unregistered')
    }
  )
})

test('provider token 过期：清缓存重签并重试一次，两次的 authorization 不同', async () => {
  await withFakeAPNs(
    (index) => (index === 0 ? { status: 403, body: '{"reason":"ExpiredProviderToken"}' } : { status: 200 }),
    async (origin, captured) => {
      const result = await sendPush(NOTIFICATION, configFor(origin), { now: 1_760_000_000_000 })

      assert.equal(result.ok, true, '重试后应当成功')
      assert.equal(captured.length, 2, '必须且只重试一次')
      assert.notEqual(
        captured[0].headers.authorization,
        captured[1].headers.authorization,
        '重试必须用重签的新 token，不能复用被拒的那个'
      )
    }
  )
})

test('载荷超 4KB：本地就拒，不发出任何请求', async () => {
  await withFakeAPNs(
    () => ({ status: 200 }),
    async (origin, captured) => {
      const result = await sendPush(
        { ...NOTIFICATION, payload: { aps: { alert: { body: 'x'.repeat(APNS_MAX_PAYLOAD_BYTES) } } } },
        configFor(origin)
      )
      assert.equal(result.ok, false)
      assert.equal(result.reason, 'PayloadTooLarge')
      assert.equal(captured.length, 0, '超限载荷不该发出去')
    }
  )
})

test('本地校验：没配好 / token 非法都不发请求', async () => {
  await withFakeAPNs(
    () => ({ status: 200 }),
    async (origin, captured) => {
      assert.equal((await sendPush(NOTIFICATION, null)).reason, 'NotConfigured')
      assert.equal(
        (await sendPush({ ...NOTIFICATION, deviceToken: 'not-hex' }, configFor(origin))).reason,
        'InvalidDeviceToken'
      )
      assert.equal(captured.length, 0)
    }
  )
})

test('超时：不挂住调用方，返回 Timeout', async () => {
  const server = http2.createServer()
  // 收到请求但**永不响应**，模拟 APNs 卡住
  server.on('stream', () => {})
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const origin = `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}`

  resetAPNsCachesForTest()
  try {
    const startedAt = Date.now()
    const result = await sendPush(NOTIFICATION, configFor(origin), { timeoutMs: 150 })
    const elapsed = Date.now() - startedAt

    assert.equal(result.ok, false)
    assert.equal(result.reason, 'Timeout')
    assert.ok(elapsed < 2000, `必须按时返回（实测 ${elapsed}ms）`)
  } finally {
    resetAPNsCachesForTest()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
})

test('连接被服务端掐断后，下一次发送会重建连接（不是一直失败）', async () => {
  const sessions: http2.ServerHttp2Session[] = []
  let shouldKill = true
  const server = http2.createServer()
  server.on('session', (session) => sessions.push(session))
  server.on('stream', (stream) => {
    stream.respond({ ':status': 200 })
    stream.end()
    if (shouldKill) {
      shouldKill = false
      // 模拟 serverless 实例被冻结/回收后连接失效
      setTimeout(() => sessions.forEach((session) => session.destroy()), 10)
    }
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const origin = `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}`

  resetAPNsCachesForTest()
  try {
    const first = await sendPush(NOTIFICATION, configFor(origin))
    assert.equal(first.ok, true)

    await new Promise((resolve) => setTimeout(resolve, 60)) // 等连接被销毁

    const second = await sendPush(NOTIFICATION, configFor(origin))
    assert.equal(second.ok, true, '连接失效后必须自动重连，否则线上会「第一条成功、之后全失败」')
  } finally {
    resetAPNsCachesForTest()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
})

// ---------------------------------------------------------------------------
// 3. 结构性
// ---------------------------------------------------------------------------

test('结构性：APNs 客户端里不许出现 fetch(', () => {
  const source = readFileSync('server/lib/apns.ts', 'utf8')
  // 允许注释里提到（文件头就是在解释为什么不能用它）
  const withoutComments = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
  assert.equal(
    withoutComments.includes('fetch('),
    false,
    'Node 的 fetch 是 HTTP/1.1，连不上 APNs（实测 code=000）。这条断言防的是"顺手改成 fetch"'
  )
})
