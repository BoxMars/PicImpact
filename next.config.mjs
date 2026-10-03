import createNextIntlPlugin from 'next-intl/plugin'
import bundleAnalyzer from '@next/bundle-analyzer'
import withPWA from 'next-pwa'

const withNextIntl = createNextIntlPlugin('./i18n.ts')

/** @type {import('next').NextConfig} */
let nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  compiler: {
    removeConsole: {
      exclude: ['error'],
    },
  },
  serverExternalPackages: ['pg'],
  typescript: {
    ignoreBuildErrors: true,
  },
  images: {
    // 源站是 Vercel（前面是 Cloudflare 代理）。Vercel 的图片优化结果是**边缘缓存**的
    // （实测 cf-cache-status: HIT），因此公共画廊图片已移除 unoptimized —— 原先保留它的
    // 理由是「/_next/image 无扩展名、CF 不缓存、每张都打源站跑 sharp」，那只在
    // CF 直连源站时成立。
    formats: ['image/avif', 'image/webp'],
    // 缩略图 URL 是内容哈希（cuid）且对象不可变，可以放心长缓存优化结果。
    minimumCacheTTL: 31536000,
    // 默认是 attachment，会让直接打开图片链接变成下载；画廊场景应为 inline。
    contentDispositionType: 'inline',
    localPatterns: [
      {
        pathname: '/api/public/url-proxy',
      },
    ],
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**',
      },
      {
        protocol: 'http',
        hostname: '**',
      },
    ],
  },
}

if (process.env.ANALYZE === 'true') {
  nextConfig = bundleAnalyzer({
    enabled: true,
  })(nextConfig)
}

// 添加 PWA 配置
const pwaConfig = withPWA({
  dest: 'public',
  register: true,
  skipWaiting: true,
  disable: process.env.NODE_ENV === 'development'
})(nextConfig)

export default withNextIntl(pwaConfig)
