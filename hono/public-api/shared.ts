import 'server-only'

/**
 * 公开 API 的版本登记表。
 *
 * **规则：一旦发布，版本号永久保留在数组里。** 旧版 App 永远无法被强制升级，
 * 删掉一个版本就等于让那部分用户直接不可用。要下线某个版本，走
 * docs/superpowers/api/public-api-v1.md 里的「弃用流程」（加响应头 + 公告期），
 * 而不是从代码里删掉。
 */
export const PUBLIC_API_VERSIONS = ['v1'] as const

export type PublicApiVersion = (typeof PUBLIC_API_VERSIONS)[number]

/**
 * 分页大小。服务端查询里 LIMIT 是写死的 24（server/db/query/images.ts 的 DEFAULT_SIZE），
 * 因此公开 API **不提供 size 参数** —— 提供却不能生效比不提供更糟。
 * 客户端请翻页，页大小从响应的 `pageSize` 读取，不要硬编码。
 */
export const PAGE_SIZE = 24

export interface ApiEnvelope<T> {
  code: number
  message: string
  data: T
}

export function ok<T>(data: T, message = 'ok'): ApiEnvelope<T> {
  return { code: 200, message, data }
}

export interface ApiHeaderOptions {
  /** 该版本已进入弃用期 */
  deprecated?: boolean
  /** 弃用版本的停止服务时间（HTTP `Sunset` 头，RFC 8594，格式为 HTTP-date） */
  sunset?: string
}

/**
 * 统一响应头。
 *
 * `Cache-Control: public, s-maxage=60, ...` 是刻意加的：这些接口只读、无鉴权、不依赖 Cookie，
 * 而服务端数据本身已经由 `unstable_cache` 缓存 60s（与 revalidate 一致）。
 * 头部设成 public 可以让 Cloudflare 在边缘直接命中，App 端首屏会明显更快。
 * **不要**给任何依赖鉴权或 Cookie 的接口加这个头。
 */
export function apiHeaders(
  version: PublicApiVersion,
  options: ApiHeaderOptions = {}
): Record<string, string> {
  const headers: Record<string, string> = {
    'X-API-Version': version,
    'Cache-Control': 'public, s-maxage=60, stale-while-revalidate=300',
  }
  if (options.deprecated) headers['X-API-Deprecated'] = 'true'
  if (options.sunset) headers['Sunset'] = options.sunset
  return headers
}

/**
 * 解析分页参数。页码非法时回退到 1 而不是报错 —— 客户端把 `page` 传成空串、
 * `NaN` 或负数都不该让列表打不开。
 */
export function parsePage(raw: string | undefined): number {
  const n = Number.parseInt(raw ?? '1', 10)
  return Number.isFinite(n) && n >= 1 ? n : 1
}
