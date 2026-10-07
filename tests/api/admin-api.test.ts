import assert from 'node:assert/strict'
import { test } from 'node:test'

import { Hono } from 'hono'

import { createAdminApi, type AdminApiDeps, type RegisterImageInput } from '~/hono/admin/api'
import { toAdminImageSummary } from '~/server/lib/admin-api'
import { buildUploadKey, extensionOf, isKeyWithinFolder, isSafeAlbumValue, isUrlUnderPrefix } from '~/server/lib/upload-key'

/**
 * `/api/v1/admin/*` 的单测。
 *
 * ## 为什么用 node:test 而不是 vitest/jest
 * 本仓库的服务端没有任何测试框架（package.json 里没有 test 脚本，也没有 vitest/jest 配置），
 * 既有的"可核对的验证"都是 `tsx` 脚本（如 `scripts/api/verify-contract.ts`）。
 * Node 自带 `node:test`，配合已有的 `tsx` 就能跑 TS 且**不引入新依赖**：
 *   node --import tsx --test tests/api/*.test.ts
 *
 * ## 为什么用依赖注入的路由工厂
 * `hono/admin/index.ts`（真实依赖）带 `import 'server-only'`，在纯 Node 下 import 就抛错；
 * 而且单测不该连生产 Supabase、更不该真的去签一个 R2 URL。
 * 所以这里只测 `hono/admin/api.ts` 的工厂：会话、存储、入库全是假的。
 * **代价**：真实装配（真会话校验 / 真签名 / 真入库）不被这层覆盖，只能靠 curl 打真接口验。
 */

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

type Captured = {
  signedKeys: string[]
  registered: RegisterImageInput[]
  deleted: string[]
  invalidated: number
}

const SESSION = { userId: 'u_1', email: 'admin@example.com' }
const TARGET = { folder: 'images', publicPrefix: 'https://felina-asset.boxz.dev' }

function makeDeps(
  options: {
    session?: typeof SESSION | null
    albumExists?: boolean
    id?: string
    signThrows?: boolean
    registerThrows?: boolean
    rows?: Record<string, any>[]
    total?: number
  } = {},
): { deps: AdminApiDeps; captured: Captured } {
  const captured: Captured = { signedKeys: [], registered: [], deleted: [], invalidated: 0 }
  const deps: AdminApiDeps = {
    async getSession() {
      return options.session === undefined ? SESSION : options.session
    },
    async storageTarget() {
      return TARGET
    },
    async albumExists() {
      return options.albumExists ?? true
    },
    async signPutUrl({ key }) {
      if (options.signThrows) throw new Error('r2 挂了')
      captured.signedKeys.push(key)
      return `https://r2.example.com/${key}?X-Amz-Signature=stub`
    },
    async registerImage(input) {
      if (options.registerThrows) throw new Error('db 挂了')
      captured.registered.push(input)
      return {
        id: 'clx0000000000000000000001',
        url: input.url,
        previewUrl: `${input.url.replace(/\.[a-z0-9]+$/i, '')}.preview.webp`,
        width: 4032,
        height: 3024,
        blurhash: 'SERVER_SIDE_HASH',
        albumValue: input.albumValue,
        show: 0,
        showOnMainpage: 0,
      }
    },
    async listImages() {
      return { total: options.total ?? 1, rows: options.rows ?? [] }
    },
    async deleteImage(id) {
      captured.deleted.push(id)
    },
    newId() {
      return options.id ?? 'clxstubid0000000000000001'
    },
    invalidate() {
      captured.invalidated += 1
    },
  }
  return { deps, captured }
}

function app(deps: AdminApiDeps): Hono {
  return createAdminApi(deps)
}

const json = (body: unknown): RequestInit => ({
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
})

const SIGN_BODY = {
  filename: 'IMG_0001.HEIC',
  contentType: 'image/heic',
  albumValue: '/daily',
  size: 3_560_000,
}

// ---------------------------------------------------------------------------
// 1. 未登录一律被拒
// ---------------------------------------------------------------------------

test('未登录：三个端点都返回 401 JSON', async () => {
  const { deps } = makeDeps({ session: null })
  const api = app(deps)

  const sign = await api.request('/uploads/sign', json(SIGN_BODY))
  assert.equal(sign.status, 401)
  assert.deepEqual(await sign.json(), { code: 401, message: 'authentication failed' })

  const register = await api.request(
    '/images',
    json({ albumValue: '/daily', url: `${TARGET.publicPrefix}/images/daily/a.jpg` }),
  )
  assert.equal(register.status, 401)

  const list = await api.request('/images?page=1')
  assert.equal(list.status, 401)

  const del = await api.request('/images/clx0000000000000000000001', { method: 'DELETE' })
  assert.equal(del.status, 401)
})

test('未登录时连参数都不看（不会泄露"这个相册存不存在"）', async () => {
  const { deps, captured } = makeDeps({ session: null })
  const res = await app(deps).request('/uploads/sign', json({ filename: '', contentType: '', albumValue: '' }))
  assert.equal(res.status, 401)
  assert.equal(captured.signedKeys.length, 0)
})

// ---------------------------------------------------------------------------
// 2. 预签名：路径穿越 / 超范围前缀
// ---------------------------------------------------------------------------

test('路径穿越的文件名一律被拒（400 invalid_filename）', async () => {
  const { deps, captured } = makeDeps()
  const api = app(deps)

  const evil = [
    '../../etc/passwd.jpg',
    '..\\..\\windows\\evil.jpg',
    'sub/dir/a.jpg',
    '/absolute/a.jpg',
    'a\0.jpg',
    'a.jpg\r\nX-Injected: 1',
    '.jpg',
    'noextension',
    'shell.php',
  ]

  for (const filename of evil) {
    const res = await api.request('/uploads/sign', json({ ...SIGN_BODY, filename }))
    assert.equal(res.status, 400, `应拒绝 filename=${JSON.stringify(filename)}`)
    assert.equal((await res.json()).message, 'invalid_filename')
  }
  assert.equal(captured.signedKeys.length, 0, '被拒的请求不能签出任何 URL')
})

test('相册值里的穿越与反斜杠一律被拒', async () => {
  const { deps } = makeDeps()
  const api = app(deps)

  for (const albumValue of ['/../../etc', '/daily/../../x', '/daily//x', 'daily', '/daily\\x', '/daily\nx', '/']) {
    const res = await api.request('/uploads/sign', json({ ...SIGN_BODY, albumValue }))
    assert.equal(res.status, 400, `应拒绝 albumValue=${JSON.stringify(albumValue)}`)
  }
})

test('库里不存在的相册被拒（不能让客户端把对象签进任意前缀）', async () => {
  const { deps, captured } = makeDeps({ albumExists: false })
  const res = await app(deps).request('/uploads/sign', json({ ...SIGN_BODY, albumValue: '/whatever' }))
  assert.equal(res.status, 400)
  assert.equal((await res.json()).message, 'unknown_album')
  assert.equal(captured.signedKeys.length, 0)
})

test('非图片/视频的 content type 被拒', async () => {
  const { deps } = makeDeps()
  const res = await app(deps).request(
    '/uploads/sign',
    json({ ...SIGN_BODY, contentType: 'application/x-httpd-php' }),
  )
  assert.equal(res.status, 400)
  assert.equal((await res.json()).message, 'invalid_content_type')
})

// ---------------------------------------------------------------------------
// 3. 预签名：正常签发
// ---------------------------------------------------------------------------

test('正常签发：key 落在相册目录下，且只签一次', async () => {
  const { deps, captured } = makeDeps({ id: 'clxabc123' })
  const res = await app(deps).request('/uploads/sign', json(SIGN_BODY))

  assert.equal(res.status, 200)
  const payload = await res.json()
  assert.equal(payload.code, 200)
  assert.deepEqual(payload.data, {
    key: 'images/daily/clxabc123.heic',
    uploadUrl: 'https://r2.example.com/images/daily/clxabc123.heic?X-Amz-Signature=stub',
    publicUrl: 'https://felina-asset.boxz.dev/images/daily/clxabc123.heic',
    contentType: 'image/heic',
    expiresInSeconds: 900,
  })
  assert.deepEqual(captured.signedKeys, ['images/daily/clxabc123.heic'])
})

test('签发失败返回 500 sign_failed（不是把异常直接漏出去）', async () => {
  const { deps } = makeDeps({ signThrows: true })
  const res = await app(deps).request('/uploads/sign', json(SIGN_BODY))
  assert.equal(res.status, 500)
  assert.equal((await res.json()).message, 'sign_failed')
})

test('对象名由服务端生成：客户端给的文件名只用来取扩展名', async () => {
  const { deps } = makeDeps({ id: 'serverGeneratedName' })
  const res = await app(deps).request('/uploads/sign', json({ ...SIGN_BODY, filename: 'my lovely photo.JPG' }))
  const payload = await res.json()
  assert.equal(payload.data.key, 'images/daily/serverGeneratedName.jpg')
})

// ---------------------------------------------------------------------------
// 4. 登记
// ---------------------------------------------------------------------------

const REGISTER_BODY = {
  albumValue: '/daily',
  url: 'https://felina-asset.boxz.dev/images/daily/clxabc123.jpg',
  imageName: 'IMG_0001.HEIC',
  title: '标题',
  detail: '',
  labels: ['标签'],
  width: 1,
  height: 1,
  lat: '',
  lon: '',
}

test('正常登记：入库且 show / show_on_mainpage 被强制为 0', async () => {
  const { deps, captured } = makeDeps()
  const res = await app(deps).request('/images', json(REGISTER_BODY))

  assert.equal(res.status, 200)
  const payload = await res.json()
  assert.equal(payload.data.id, 'clx0000000000000000000001')
  assert.equal(payload.data.show, 0)
  assert.equal(payload.data.showOnMainpage, 0)
  // 客户端的 blurhash / preview_url 不该进来；服务端算的那份才算
  assert.equal(payload.data.blurhash, 'SERVER_SIDE_HASH')

  assert.equal(captured.registered.length, 1)
  const input = captured.registered[0]
  assert.equal(input.show, 0)
  assert.equal(input.showOnMainpage, 0)
  assert.equal(input.lat, '', '缺省 lat 要写空串，不能变成 "undefined"')
  assert.equal(input.lon, '')
  assert.equal(input.type, 1, '缺省 type = 1（普通图片）')
  assert.equal(captured.invalidated, 1, '登记后必须失效图片缓存')
})

test('登记请求里塞 show=1 / preview_url / blurhash 一律无效（zod 丢弃未声明字段）', async () => {
  const { deps, captured } = makeDeps()
  const res = await app(deps).request(
    '/images',
    json({
      ...REGISTER_BODY,
      show: 1,
      show_on_mainpage: 1,
      preview_url: 'https://evil.example.com/x.webp',
      blurhash: 'CLIENT_HASH',
      del: 1,
      id: 'hacked',
    }),
  )

  assert.equal(res.status, 200)
  const input = captured.registered[0]
  assert.equal(input.show, 0)
  assert.equal(input.showOnMainpage, 0)
  assert.equal('preview_url' in input, false)
  assert.equal('blurhash' in input, false)
  assert.equal('del' in input, false)
  assert.equal('id' in input, false)
})

test('登记一个不属于本站存储的 URL 被拒（防 SSRF：预览图那步会真的去 fetch）', async () => {
  const { deps, captured } = makeDeps()
  const res = await app(deps).request(
    '/images',
    json({ ...REGISTER_BODY, url: 'http://169.254.169.254/latest/meta-data/' }),
  )
  assert.equal(res.status, 400)
  assert.equal((await res.json()).message, 'url_not_in_storage')
  assert.equal(captured.registered.length, 0)
})

test('登记入库失败返回 500 register_failed，并留下可捞回孤儿的日志', async () => {
  const { deps } = makeDeps({ registerThrows: true })
  const res = await app(deps).request('/images', json(REGISTER_BODY))
  assert.equal(res.status, 500)
  assert.equal((await res.json()).message, 'register_failed')
})

// ---------------------------------------------------------------------------
// 5. 列表与删除
// ---------------------------------------------------------------------------

test('列表：返回分页信息与映射后的 items', async () => {
  const row = {
    id: 'clx1',
    url: 'https://felina-asset.boxz.dev/images/daily/a.jpg',
    preview_url: 'https://felina-asset.boxz.dev/images/daily/preview/a.webp',
    title: '标题',
    detail: '',
    width: 4032,
    height: 3024,
    show: 0,
    show_on_mainpage: 0,
    labels: ['标签', 123],
    created_at: new Date('2026-10-07T00:00:00.000Z'),
    album_value: '/daily',
    album_name: '大福日常',
    exif: { model: 'iPhone 15', lens_model: 'x', data_time: '2026:10:06 12:00:00' },
  }
  const { deps } = makeDeps({ rows: [row], total: 58 })
  const res = await app(deps).request('/images?page=2&pageSize=24')

  assert.equal(res.status, 200)
  const payload = await res.json()
  assert.deepEqual(
    { page: payload.data.page, pageSize: payload.data.pageSize, total: payload.data.total, hasMore: payload.data.hasMore },
    { page: 2, pageSize: 24, total: 58, hasMore: true },
  )
  assert.equal(payload.data.items.length, 1)
  assert.equal(payload.data.items[0].previewUrl, row.preview_url)
  assert.deepEqual(payload.data.items[0].labels, ['标签'], '非字符串 label 要被丢掉')
  assert.equal(payload.data.items[0].exif.model, 'iPhone 15')
})

test('列表：pageSize 超过上限被拒（防止一次拉爆）', async () => {
  const { deps } = makeDeps()
  const res = await app(deps).request('/images?pageSize=1000')
  assert.equal(res.status, 400)
})

test('删除：合法 id 走软删除并失效缓存', async () => {
  const { deps, captured } = makeDeps()
  const res = await app(deps).request('/images/clx0000000000000000000001', { method: 'DELETE' })

  assert.equal(res.status, 200)
  assert.deepEqual(await res.json(), { code: 200, data: { id: 'clx0000000000000000000001', deleted: true } })
  assert.deepEqual(captured.deleted, ['clx0000000000000000000001'])
  assert.equal(captured.invalidated, 1)
})

test('删除：非法 id 被拒，且不会碰到数据库', async () => {
  const { deps, captured } = makeDeps()
  // 空 id 连路由都匹配不上（`/images/`），所以是 404；其余形状不合法的必须 400
  const emptyRes = await app(deps).request('/images/', { method: 'DELETE' })
  assert.equal(emptyRes.status, 404)

  for (const id of ['../../etc', 'a b', 'x'.repeat(51), 'a/b']) {
    const res = await app(deps).request(`/images/${encodeURIComponent(id)}`, { method: 'DELETE' })
    assert.equal(res.status, 400, `应拒绝 id=${JSON.stringify(id)}`)
  }
  assert.equal(captured.deleted.length, 0)
})

// ---------------------------------------------------------------------------
// 6. 纯函数：key 布局必须与 web 原实现逐字符一致
// ---------------------------------------------------------------------------

/** `hono/file.ts` 改动**之前**内联的表达式，原样抄下来当基准 */
function legacyFilePath(storageFolder: string, type: string, filename: string): string {
  return storageFolder && storageFolder !== '/'
    ? type && type !== '/' ? `${storageFolder}${type}/${filename}` : `${storageFolder}/${filename}`
    : type && type !== '/' ? `${type.slice(1)}/${filename}` : `${filename}`
}

test('buildUploadKey 与 web 原实现的输出逐字符一致', () => {
  const folders = ['images', 'images', '', '/', 'photos/nested']
  const albums = ['/daily', '/', '', 'daily', '/a/b']
  const names = ['clx1.jpg', 'a.webp']

  for (const folder of folders) {
    for (const album of albums) {
      for (const name of names) {
        assert.equal(
          buildUploadKey(folder, album, name),
          legacyFilePath(folder, album, name),
          `folder=${JSON.stringify(folder)} album=${JSON.stringify(album)} name=${name}`,
        )
      }
    }
  }
})

test('isKeyWithinFolder 只放行存储前缀内的 key', () => {
  assert.equal(isKeyWithinFolder('images/daily/a.jpg', 'images'), true)
  assert.equal(isKeyWithinFolder('images/a.jpg', 'images'), true)
  assert.equal(isKeyWithinFolder('images', 'images'), false)
  assert.equal(isKeyWithinFolder('imagesx/a.jpg', 'images'), false, '同前缀但不是子目录')
  assert.equal(isKeyWithinFolder('../images/a.jpg', 'images'), false)
  assert.equal(isKeyWithinFolder('images/daily/../../secret', 'images'), false)
  assert.equal(isKeyWithinFolder('/images/a.jpg', 'images'), false)
  assert.equal(isKeyWithinFolder('images//a.jpg', 'images'), false)
  assert.equal(isKeyWithinFolder('images\\a.jpg', 'images'), false)
})

test('extensionOf 只认白名单里的小写扩展名', () => {
  assert.equal(extensionOf('a.JPG'), 'jpg')
  assert.equal(extensionOf('a.jpeg'), 'jpeg')
  assert.equal(extensionOf('a.heic'), 'heic')
  assert.equal(extensionOf('a.php'), null)
  assert.equal(extensionOf('a'), null)
  assert.equal(extensionOf('.jpg'), null)
  assert.equal(extensionOf('a.jpg '), 'jpg')
  assert.equal(extensionOf('dir/a.jpg'), null)
})

test('isSafeAlbumValue / isUrlUnderPrefix 的边界', () => {
  assert.equal(isSafeAlbumValue('/daily'), true)
  assert.equal(isSafeAlbumValue('/a/b-c_d.e'), true)
  assert.equal(isSafeAlbumValue(''), false)
  assert.equal(isSafeAlbumValue('/'), false)
  assert.equal(isSafeAlbumValue('/daily/'), false)
  assert.equal(isSafeAlbumValue('/../x'), false)
  assert.equal(isSafeAlbumValue('/daily?x=1'), false)

  assert.equal(isUrlUnderPrefix('https://felina-asset.boxz.dev/images/a.jpg', 'https://felina-asset.boxz.dev'), true)
  assert.equal(isUrlUnderPrefix('https://felina-asset.boxz.dev.evil.com/a.jpg', 'https://felina-asset.boxz.dev'), false)
  assert.equal(isUrlUnderPrefix('https://evil.com/a.jpg', 'https://felina-asset.boxz.dev'), false)
  assert.equal(isUrlUnderPrefix('https://felina-asset.boxz.dev/a.jpg', ''), false)
})

test('toAdminImageSummary 兜住数据库里的 null / 异构 Json', () => {
  const summary = toAdminImageSummary({
    id: 'clx1',
    url: 'https://x/a.jpg',
    preview_url: null,
    labels: null,
    exif: null,
    width: '4032',
    height: null,
    created_at: null,
  })
  assert.equal(summary.previewUrl, 'https://x/a.jpg', '没有预览图时退回原图')
  assert.deepEqual(summary.labels, [])
  assert.equal(summary.width, 4032)
  assert.equal(summary.height, 0)
  assert.equal(summary.createdAt, null)
  assert.deepEqual(summary.exif, { model: '', lensModel: '', dataTime: '' })
})
