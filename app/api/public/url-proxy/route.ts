import { NextResponse } from 'next/server'

const CACHE_CONTROL_MEDIA = 'public, max-age=31536000, immutable, stale-while-revalidate=604800'
const CACHE_CONTROL_DEFAULT = 'public, max-age=300, stale-while-revalidate=3600'
const ALLOWED_TARGET_HOST = 'felina-asset.boxz.dev'

function parseTargetUrl(target: string | null) {
  if (!target) {
    return { error: 'Missing url query parameter' as const }
  }

  try {
    const parsedUrl = new URL(target)
    if (parsedUrl.protocol !== 'https:' || parsedUrl.hostname !== ALLOWED_TARGET_HOST) {
      return { error: `Only https://${ALLOWED_TARGET_HOST} is allowed` as const }
    }
    return { parsedUrl }
  } catch {
    return { error: 'Invalid url query parameter' as const }
  }
}

function isSameOriginRequest(request: Request): boolean {
  const requestUrl = new URL(request.url)
  const origin = request.headers.get('origin')
  const referer = request.headers.get('referer')

  if (origin) {
    return origin === requestUrl.origin
  }

  if (!referer) {
    return false
  }

  try {
    return new URL(referer).origin === requestUrl.origin
  } catch {
    return false
  }
}

export async function GET(request: Request) {
  if (!isSameOriginRequest(request)) {
    return NextResponse.json({ error: 'Forbidden origin' }, { status: 403 })
  }

  const { searchParams } = new URL(request.url)
  const target = searchParams.get('url')
  const result = parseTargetUrl(target)

  if ('error' in result) {
    return NextResponse.json({ error: result.error }, { status: 403 })
  }

  try {
    const requestHeaders = new Headers()
    const accept = request.headers.get('accept')
    const ifNoneMatch = request.headers.get('if-none-match')
    const ifModifiedSince = request.headers.get('if-modified-since')
    const range = request.headers.get('range')

    if (accept) requestHeaders.set('accept', accept)
    if (ifNoneMatch) requestHeaders.set('if-none-match', ifNoneMatch)
    if (ifModifiedSince) requestHeaders.set('if-modified-since', ifModifiedSince)
    if (range) requestHeaders.set('range', range)

    const upstreamResponse = await fetch(result.parsedUrl.toString(), {
      headers: requestHeaders,
      redirect: 'follow',
    })

    const headers = new Headers()
    const contentType = upstreamResponse.headers.get('content-type')
    const cacheControl = upstreamResponse.headers.get('cache-control')
    const contentLength = upstreamResponse.headers.get('content-length')
    const contentRange = upstreamResponse.headers.get('content-range')
    const acceptRanges = upstreamResponse.headers.get('accept-ranges')
    const etag = upstreamResponse.headers.get('etag')
    const lastModified = upstreamResponse.headers.get('last-modified')
    const contentDisposition = upstreamResponse.headers.get('content-disposition')

    if (contentType) {
      headers.set('content-type', contentType)
    }
    if (cacheControl) {
      headers.set('cache-control', cacheControl)
    } else {
      const isMedia = Boolean(contentType?.startsWith('image/') || contentType?.startsWith('video/'))
      headers.set('cache-control', isMedia ? CACHE_CONTROL_MEDIA : CACHE_CONTROL_DEFAULT)
    }
    if (contentLength) headers.set('content-length', contentLength)
    if (contentRange) headers.set('content-range', contentRange)
    if (acceptRanges) headers.set('accept-ranges', acceptRanges)
    if (etag) headers.set('etag', etag)
    if (lastModified) headers.set('last-modified', lastModified)
    if (contentDisposition) headers.set('content-disposition', contentDisposition)

    headers.set('access-control-allow-origin', new URL(request.url).origin)
    headers.set('x-content-type-options', 'nosniff')

    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      headers
    })
  } catch (error) {
    console.error('Failed to fetch target url:', error)
    return NextResponse.json(
      { error: 'Failed to fetch target url' },
      { status: 502 }
    )
  }
}
