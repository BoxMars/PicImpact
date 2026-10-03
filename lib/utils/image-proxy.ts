const PROXY_ROUTE_PREFIX = '/api/public/url-proxy?url='

/**
 * 缩略图/预览图默认直连资产域。
 *
 * 实测依据（2026-10-03）：
 * - `felina-asset.boxz.dev` 的图片 GET 返回 `cf-cache-status: HIT`（`max-age=14400`），
 *   且带 `access-control-allow-origin: *`、无防盗链 —— 直连可被边缘与浏览器缓存。
 * - `/api/public/url-proxy` 无文件扩展名，Cloudflare Standard 缓存级别不存储该路径，
 *   实测恒为 `DYNAMIC` —— 每张图都要多一次源站往返，把边缘缓存的收益完全抵消。
 *
 * 因此默认直连。仅在资产域策略变更（例如移除 ACAO 或加上防盗链）时，
 * 把 ENABLE_IMAGE_PROXY 置为 true 回退到代理。
 */
const ENABLE_IMAGE_PROXY = false

export function toProxyImageUrl(rawUrl: string | null | undefined): string {
  if (!rawUrl) {
    return ''
  }

  if (!ENABLE_IMAGE_PROXY) {
    return rawUrl
  }

  if (rawUrl.startsWith(PROXY_ROUTE_PREFIX)) {
    return rawUrl
  }

  return `${PROXY_ROUTE_PREFIX}${encodeURIComponent(rawUrl)}`
}

export function isProxyImageUrl(url: string | null | undefined): boolean {
  return Boolean(url?.startsWith(PROXY_ROUTE_PREFIX))
}
