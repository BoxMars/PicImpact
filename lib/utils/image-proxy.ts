const PROXY_ROUTE_PREFIX = '/api/public/url-proxy?url='

export function toProxyImageUrl(rawUrl: string | null | undefined): string {
  if (!rawUrl) {
    return ''
  }

  if (rawUrl.startsWith(PROXY_ROUTE_PREFIX)) {
    return rawUrl
  }

  return `/api/public/url-proxy?url=${encodeURIComponent(rawUrl)}`
}

export function isProxyImageUrl(url: string | null | undefined): boolean {
  return Boolean(url?.startsWith(PROXY_ROUTE_PREFIX))
}
