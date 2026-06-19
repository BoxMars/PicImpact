import { UserFrom } from '~/components/login/user-from'
import Image from 'next/image'
import Link from 'next/link'
import { fetchSiteBranding } from '~/server/db/query/configs'

export default async function Login() {
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
      {/* Island card */}
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
        {/* Logo & title */}
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

        {/* Island divider */}
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
          <span>🏝 ISLAND LOGIN</span>
          <div style={{ flex: 1, height: 1.5, background: '#c4b89e', borderRadius: 2 }} />
        </div>

        <UserFrom />
      </div>

      {/* Decorative footer text */}
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
