import { NextRequest, NextResponse } from 'next/server'
import { getSessionCookie } from 'better-auth/cookies'

export async function proxy(request: NextRequest) {
  const sessionCookie = getSessionCookie(request, {
    cookiePrefix: 'pic-impact'
  })
  if (request.nextUrl.pathname.startsWith('/api/v1') && !sessionCookie) {
    return Response.json(
      { success: false, message: 'authentication failed' },
      { status: 401 }
    )
  }
  if (request.nextUrl.pathname.startsWith('/admin') && !sessionCookie) {
    return NextResponse.redirect(new URL('/login', request.url))
  }
  if (sessionCookie && request.nextUrl.pathname === '/login') {
    return NextResponse.redirect(new URL('/', request.url))
  }

  return NextResponse.next()
}

// Optionally, don't invoke Middleware on some paths
// Read more: https://nextjs.org/docs/app/building-your-application/routing/middleware#matcher
// 排除清单说明：原先只排除 _next/static / _next/image / favicon.ico，导致每个图片请求
// （含 /api/public/*）与 public/ 下的静态资源都要过一次中间件。首屏 24~48 个图片请求
// 全压在中间件上，是纯浪费。/admin 与 /api/v1 的鉴权保持不变。
export const config = {
  matcher: [
    // `.well-known/` 必须放行：Apple 关联域名文件（AASA）在 /.well-known/ 下，
    // 中间件一旦插手（重定向/改写），系统就取不到这份文件，密码 AutoFill 关联会失效。
    '/((?!_next/static|_next/image|api/public|\\.well-known/|favicon\\.ico|manifest\\.json|robots\\.txt|icons/|fonts/|cursor-icon\\.png|apple-touch-icon\\.png|maskable-icon\\.png|.*\\.(?:png|jpe?g|webp|avif|svg|gif|ico|woff2?|ttf|css|js|map|txt|xml)$).*)',
    '/admin/:path*',
    '/api/v1/:path*',
  ],
}