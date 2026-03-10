import { NextResponse } from 'next/server'

function parseTargetUrl(target: string | null) {
  if (!target) {
    return { error: 'Missing url query parameter' as const }
  }

  try {
    const parsedUrl = new URL(target)
    if (!['http:', 'https:'].includes(parsedUrl.protocol)) {
      return { error: 'Only http and https protocols are supported' as const }
    }
    return { parsedUrl }
  } catch {
    return { error: 'Invalid url query parameter' as const }
  }
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url)
  const target = searchParams.get('url')
  const result = parseTargetUrl(target)

  if ('error' in result) {
    return NextResponse.json({ error: result.error }, { status: 400 })
  }

  try {
    const upstreamResponse = await fetch(result.parsedUrl.toString())
    const body = await upstreamResponse.arrayBuffer()

    const headers = new Headers()
    const contentType = upstreamResponse.headers.get('content-type')
    const cacheControl = upstreamResponse.headers.get('cache-control')

    if (contentType) {
      headers.set('content-type', contentType)
    }
    if (cacheControl) {
      headers.set('cache-control', cacheControl)
    }

    headers.set('access-control-allow-origin', '*')

    return new Response(body, {
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
