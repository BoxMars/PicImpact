/**
 * 上传对象的 key（路径）构造与校验。
 *
 * ## 为什么单独抽一个模块
 * 1. **布局只能有一处定义**：object key 决定了文件落在 R2 的哪个目录，而缩略图 key 是由它派生的
 *    （`buildPreviewKey()`：`<dir>/preview/<name>.webp`，见 `server/lib/thumbnail.ts:93`）。
 *    如果 web 的 `/api/v1/file/presigned-url` 与 App 的 `/api/v1/admin/uploads/sign` 各拼一遍,
 *    两边对同一个相册就可能落进不同目录，表现为"App 传的图在 web 上看不到缩略图"。
 *    所以布局规则收在这里一处，两个接口都调它（web 侧见 `hono/file.ts`）。
 * 2. **要能在纯 Node 下被单测**：本模块刻意**不 import 任何 `server-only` 的东西**
 *    （与 `server/lib/preview-storage.ts` 同一个理由：那个包在 tsx/Node 下 import 就抛错），
 *    所以路径穿越这类纯逻辑可以直接写测试，不需要起 Next 或连数据库。
 */

/** 允许上传的扩展名。白名单而不是"取最后一个点" —— 黑名单永远漏。 */
export const ALLOWED_UPLOAD_EXTENSIONS = [
  'jpg',
  'jpeg',
  'png',
  'webp',
  'heic',
  'heif',
  'avif',
  'gif',
  // livephoto 的视频轨（`Images.type = 2` 时需要，见 prisma/schema.prisma 的注释）
  'mp4',
  'mov',
] as const

/**
 * 按既有约定拼 object key。
 *
 * 表达式与 `hono/file.ts` 原先内联的那两段**逐字符一致**（web 与 App 必须落在同一个目录）：
 * ```
 * storageFolder && storageFolder !== '/'
 *   ? type && type !== '/' ? `${storageFolder}${type}/${filename}` : `${storageFolder}/${filename}`
 *   : type && type !== '/' ? `${type.slice(1)}/${filename}`                  : `${filename}`
 * ```
 *
 * @param storageFolder `configs.r2_storage_folder`（本库为 `images`）
 * @param albumValue    相册值，形如 `/daily`（`albums.album_value`）
 * @param filename      对象名（**由服务端生成**，形如 `clx123.heic`，不是用户给的文件名）
 */
export function buildUploadKey(storageFolder: string, albumValue: string, filename: string): string {
  const folder = storageFolder ?? ''
  const type = albumValue ?? ''
  if (folder && folder !== '/') {
    return type && type !== '/'
      ? `${folder}${type}/${filename}`
      : `${folder}/${filename}`
  }
  return type && type !== '/'
    ? `${type.slice(1)}/${filename}`
    : `${filename}`
}

/**
 * 从用户给的文件名里取出**安全的**扩展名（小写，不含点）。
 *
 * 只取扩展名、不采信这个文件名的其它部分：对象名由服务端生成，客户端无从决定路径。
 * 出现路径分隔符、`..`、空字节、控制字符等一律判为非法并返回 null ——
 * 宁可返回 400 让客户端暴露问题，也不要"悄悄清洗后照收"（那样上传会静默落到意料之外的名字上）。
 */
export function extensionOf(rawFilename: string): string | null {
  if (typeof rawFilename !== 'string') return null
  const filename = rawFilename.trim()
  if (!filename || filename.length > 200) return null
  // 反斜杠也要挡：某些客户端会把 Windows 路径原样带上
  if (/[/\\]/.test(filename)) return null
  if (filename.includes('..')) return null
  if (/[\u0000-\u001f\u007f]/.test(filename)) return null

  const dot = filename.lastIndexOf('.')
  if (dot <= 0 || dot === filename.length - 1) return null
  const ext = filename.slice(dot + 1).toLowerCase()
  return (ALLOWED_UPLOAD_EXTENSIONS as readonly string[]).includes(ext) ? ext : null
}

/**
 * 相册值是否是一个安全的路径片段。
 *
 * 允许空串之外的形式：以 `/` 开头、由 `[A-Za-z0-9._-]` 组成的若干段（本库只有 `/daily`）。
 * 拒绝 `..`、空段（`//`）、以及反斜杠 —— 它们都可能让 key 逃出存储前缀。
 */
export function isSafeAlbumValue(albumValue: string): boolean {
  if (typeof albumValue !== 'string') return false
  if (albumValue.length === 0 || albumValue.length > 200) return false
  if (!albumValue.startsWith('/')) return false
  if (/[\\\u0000-\u001f\u007f]/.test(albumValue)) return false

  const segments = albumValue.slice(1).split('/')
  if (segments.length === 0) return false
  return segments.every((segment) => segment.length > 0 && segment !== '.' && segment !== '..' && /^[A-Za-z0-9._-]+$/.test(segment))
}

/**
 * 最终 key 是否确实落在存储根目录内。
 *
 * 这是**兜底断言**：key 由 `buildUploadKey()` 生成、相册值也校验过了，正常情况下必然成立。
 * 但"签发一个能写到桶里任意位置/别的桶的 URL"是本批次风险最高的一件事（Review Focus 1），
 * 所以出 URL 之前再确认一次，代价是一次字符串比较。
 */
export function isKeyWithinFolder(key: string, storageFolder: string): boolean {
  if (typeof key !== 'string' || key.length === 0) return false
  if (key.startsWith('/') || /[\\\u0000-\u001f\u007f]/.test(key)) return false
  const segments = key.split('/')
  if (segments.some((segment) => segment.length === 0 || segment === '.' || segment === '..')) return false

  const folder = (storageFolder ?? '').replace(/^\/+|\/+$/g, '')
  if (!folder) return true
  return key.startsWith(`${folder}/`)
}

/**
 * 公开 URL 是否属于某个存储前缀（用于拒绝"登记一个不属于本站存储的 URL"）。
 *
 * 为什么必须要这道校验：登记入库时服务端会**真的去 fetch 这个 URL** 来生成缩略图
 * （`server/lib/preview-storage.ts:145`）。不加校验的话，一个已登录的账号就能让服务端
 * 去请求任意内网地址（SSRF）。前缀校验把可请求的范围锁死在自家存储上。
 */
export function isUrlUnderPrefix(url: string, publicPrefix: string): boolean {
  if (typeof url !== 'string' || typeof publicPrefix !== 'string') return false
  const prefix = publicPrefix.replace(/\/+$/, '')
  if (!prefix) return false
  return url.startsWith(`${prefix}/`)
}
