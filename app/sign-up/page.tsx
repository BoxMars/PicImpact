import Image from 'next/image'
import Link from 'next/link'
import { SignUpForm } from '~/components/sign-up/sign-up-from'
import { checkUserExists } from '~/server/db/query/users'
import { redirect } from 'next/navigation'
import { fetchSiteBranding } from '~/server/db/query/configs'

/**
 * 必须保持动态渲染。
 * 该页依赖鉴权/用户态：一旦被静态化并进入边缘缓存，边缘会在**不调用函数与中间件**
 * 的情况下直接返回缓存内容，从而把非公开数据暴露给未登录访客。
 */
export const dynamic = 'force-dynamic'

export default async function SignUp() {
  const userExists = await checkUserExists()

  if (userExists) {
    redirect('/login')
  }

  const branding = await fetchSiteBranding()

  return (
    <div
      style={{
        display: 'flex',
        minHeight: '100svh',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 24,
        padding: '24px 16px',
        background: '#f8f8f0',
        backgroundImage: `
          radial-gradient(circle, rgba(25,200,185,0.07) 1.5px, transparent 1.5px) 0 0/32px 32px,
          radial-gradient(circle, rgba(25,200,185,0.04) 1px, transparent 1px) 8px 8px/16px 16px
        `,
      }}
    >
      <div
        style={{
          width: '100%',
          maxWidth: 400,
          display: 'flex',
          flexDirection: 'column',
          gap: 24,
          background: 'rgb(247, 243, 223)',
          border: '2.5px solid #c4b89e',
          borderRadius: 24,
          padding: '32px 28px',
          boxShadow: '0 6px 0 0 #bdaea0, 0 12px 40px rgba(121,79,39,0.12)',
        }}
      >
        <Link
          href="/"
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            alignSelf: 'center',
            textDecoration: 'none',
            color: '#794f27',
            fontWeight: 700,
            fontSize: 18,
            letterSpacing: '0.02em',
          }}
        >
          <div
            style={{
              width: 40,
              height: 40,
              borderRadius: 14,
              overflow: 'hidden',
              border: '2px solid #c4b89e',
              flexShrink: 0,
            }}
          >
            <Image
              src={branding.logoUrl}
              alt="Logo"
              width={40}
              height={40}
              style={{ objectFit: 'cover', width: 40, height: 40 }}
              unoptimized
            />
          </div>
          {branding.title}
        </Link>

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            color: '#9f927d',
            fontSize: 12,
            fontWeight: 600,
            letterSpacing: '0.05em',
          }}
        >
          <div style={{ flex: 1, height: 1.5, background: '#c4b89e', borderRadius: 2 }} />
          <span>🌱 NEW ISLANDER</span>
          <div style={{ flex: 1, height: 1.5, background: '#c4b89e', borderRadius: 2 }} />
        </div>

        <SignUpForm />
      </div>

      <p
        style={{
          color: '#9f927d',
          fontSize: 12,
          fontWeight: 500,
          letterSpacing: '0.04em',
        }}
      >
        🌿 大福映画 Felina Gallery
      </p>
    </div>
  )
}
