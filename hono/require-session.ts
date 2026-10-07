import type { MiddlewareHandler } from 'hono'

/**
 * `/api/v1/*` 写接口与敏感读接口的**会话校验中间件**。
 *
 * ## 为什么必须有它
 * `proxy.ts` 那道门禁只用了 better-auth 的 `getSessionCookie()`，而它**只把 cookie 解析出来返回**，
 * 既不验签也不查库。也就是说：只要请求里带一个名为 `pic-impact.session_token` 的任意值，
 * 就能穿过中间件。而 `/api/v1/*` 下的写接口（传图、改图、删图、改配置、读 R2/S3 密钥…）
 * 原先**在路由内部也不再校验**，于是伪造 cookie 就能改生产数据、读走存储密钥。
 *
 * 修法：真正的校验必须在**路由里**做。这里提供唯一的一份实现，所有 `/api/v1` 子路由
 * 在文件顶部 `app.use('*', requireSession)` 挂上即可（不要各写一遍 —— 漏一个就等于没修）。
 *
 * ## 为什么本文件不 import `server-only`、也不在顶层 import auth
 * 1. 单测要能在纯 Node 下 import 它来验证"没会话就 401、有会话就放行"（`tests/api/require-session.test.ts`）；
 * 2. 真实依赖（better-auth 的 `auth`）改成**动态 import**，只在实际处理请求时才加载。
 *
 * 注意：`server-only` 的保护并没有丢 —— 本模块只被同样带 `import 'server-only'`
 * 的路由模块引用，客户端组件不可能引用到它。
 */

export type SessionLookup = (headers: Headers) => Promise<{ userId: string; email: string } | null>

/** 401 的响应体。与 `server/lib/admin-api.ts` 的 `apiError()` 保持同一形状。 */
export const UNAUTHENTICATED_BODY = { code: 401, message: 'authentication failed' } as const

/**
 * 用给定的会话查询函数构造中间件（便于单测注入替身）。
 *
 * 查询函数返回 null 即视为未登录 → `401`，**不会**进入下游 handler（所以不可能产生数据变更）。
 */
export function createRequireSession(lookup: SessionLookup): MiddlewareHandler {
  return async (c, next) => {
    const session = await lookup(c.req.raw.headers)
    if (!session) {
      return c.json(UNAUTHENTICATED_BODY, 401)
    }
    await next()
  }
}

/**
 * 真实实现：用 better-auth 的服务端 API 校验会话（会验签，cookie cache 命中时不必查库）。
 *
 * ⚠️ 不要再退回 `getSessionCookie()`：那个函数只判断 cookie 在不在。
 */
export const requireSession: MiddlewareHandler = createRequireSession(async (headers) => {
  const { auth } = await import('~/server/auth')
  const session = await auth.api.getSession({ headers })
  if (!session?.user) return null
  return { userId: session.user.id, email: session.user.email }
})
