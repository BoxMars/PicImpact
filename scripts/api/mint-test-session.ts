/**
 * 本地验证工具：为一个已存在的用户**临时**签发一个会话 cookie。
 *
 * ## 为什么需要它
 * 新增的管理接口（`/api/v1/admin/*`）都要会话，而 curl 验证不能靠"问人要管理员密码"。
 * 这个脚本用 better-auth 自己的内部适配器建一条 session 行，并按 better-auth 的签名规则
 * （`makeSignature(token, secret)`，即 `<token>.<base64(HMAC-SHA256)>`）拼出 cookie，
 * 于是 curl 能带着一个**服务端真正认的**会话打接口。
 *
 * ## ⚠️ 边界
 * - 只在**本机开发/验证**时使用。它需要 `.env` 里的数据库凭据，本身不经过任何 HTTP 接口，
 *   所以不是一个可被远程利用的后门；但也不能在服务器上跑。
 * - 用完请立刻用 `--revoke <token>` 删掉这条会话（脚本会打印 TOKEN）。
 *
 * 用法：
 *   npx tsx scripts/api/mint-test-session.ts [email]
 *   npx tsx scripts/api/mint-test-session.ts --revoke <token>
 */
import { makeSignature } from 'better-auth/crypto'

import { auth } from '~/server/auth'
import { db } from '~/server/lib/db'

async function main() {
  const args = process.argv.slice(2)

  const revokeIndex = args.indexOf('--revoke')
  if (revokeIndex !== -1) {
    const target = args[revokeIndex + 1]
    if (!target) {
      console.error('用法：--revoke <token 或 session id>')
      process.exit(1)
    }
    // 两个都能删：脚本打印的是 TOKEN，而排查时手头往往只有 session 表的 id
    const deleted = await db.session.deleteMany({ where: { OR: [{ token: target }, { id: target }] } })
    console.log(`REVOKED=${deleted.count}`)
    await db.$disconnect()
    return
  }

  const email = args[0] ?? 'me@boxz.dev'
  const user = await db.user.findFirst({ where: { email } })
  if (!user) {
    console.error(`找不到用户：${email}`)
    process.exit(1)
  }

  const context = await auth.$context
  const session = await context.internalAdapter.createSession(user.id)
  const signed = `${session.token}.${await makeSignature(session.token, context.secret)}`

  console.log(`USER=${user.email}`)
  console.log(`COOKIE_NAME=${context.authCookies.sessionToken.name}`)
  console.log(`COOKIE=${context.authCookies.sessionToken.name}=${signed}`)
  console.log(`TOKEN=${session.token}`)
  console.log(`EXPIRES_AT=${new Date(session.expiresAt).toISOString()}`)

  await db.$disconnect()
}

main().catch(async (error) => {
  console.error('失败：', error)
  await db.$disconnect().catch(() => {})
  process.exit(1)
})
