import 'server-only'
import { handle } from 'hono/vercel'
import { Hono } from 'hono'
import route from '~/hono'
import download from '~/hono/open/download'
import images from '~/hono/open/images'
import publicApi from '~/hono/public-api'

const app = new Hono().basePath('/api')

app.route('/v1', route)
// 注意只有 /v1 开头是需要鉴权的
app.route('/public/download', download)
app.route('/public/images', images)
// 版本化的公开只读 API（供 iOS 等外部客户端使用）。
// proxy.ts 的 matcher 已排除 api/public，因此这里天然不需要会话。
// 契约与版本政策见 docs/superpowers/api/public-api-v1.md
app.route('/public', publicApi)
app.notFound((c) => {
  return c.text('not found', 404)
})

export const GET = handle(app)
export const POST = handle(app)
export const PUT = handle(app)
export const DELETE = handle(app)
export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'

export default app
