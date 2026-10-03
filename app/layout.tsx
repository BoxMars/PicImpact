import type { Metadata } from 'next/types'

import { ThemeProvider } from '~/app/providers/next-ui-providers'
import { ToasterProviders } from '~/app/providers/toaster-providers'
import { ProgressBarProviders } from '~/app/providers/progress-bar-providers'
import { ButtonStoreProvider } from '~/app/providers/button-store-providers'

import '~/style/globals.css'
import { fetchConfigsByKeys } from '~/server/db/query/configs'

// 公开页的 intl provider 放在客户端模块里（见该文件注释：从服务端入口导入
// NextIntlClientProvider 会 await getFormats()/getConfigNow()，从而读 cookie
// 并把整棵路由树变成动态渲染）。管理端仍按 cookie 选语言，见 app/admin/layout.tsx。
import { IntlProvider } from '~/app/providers/intl-provider'
import { ConfigStoreProvider } from '~/app/providers/config-store-providers'
import Script from 'next/script'
import { defaultLocale } from '~/i18n'

type ConfigItem = {
  id: string;
  config_key: string;
  config_value: string | null;
  detail: string | null;
}

export async function generateMetadata(): Promise<Metadata> {
  const data = await fetchConfigsByKeys([
    'custom_title',
    'custom_favicon_url'
  ])

  return {
    title: data?.find((item: ConfigItem) => item.config_key === 'custom_title')?.config_value || '大福映画 Felina Gallery',
    icons: { icon: data?.find((item: ConfigItem) => item.config_key === 'custom_favicon_url')?.config_value || './favicon.ico' },
    manifest: '/manifest.json',
    appleWebApp: {
      capable: true,
      statusBarStyle: 'default',
      title: '大福映画 Felina Gallery',
    }
  }
}

export const viewport = {
  width: 'device-width',
  initialScale: 1,
  maximumScale: 1,
  themeColor: '#000000',
  viewportFit: 'cover',
}

export default async function RootLayout({
  children,
  modal,
}: Readonly<{
  children: React.ReactNode;
  modal: React.ReactNode;
}>) {

  const data = await fetchConfigsByKeys([
    'umami_analytics',
    'umami_host'
  ])

  const umamiHost = data?.find((item: ConfigItem) => item.config_key === 'umami_host')?.config_value || 'https://cloud.umami.is/script.js'
  const umamiAnalytics = data?.find((item: ConfigItem) => item.config_key === 'umami_analytics')?.config_value

  return (
    <html className="overflow-y-auto scrollbar-hide" lang={defaultLocale} suppressHydrationWarning>
    <head>
      <link rel="manifest" href="/manifest.json" />
      <meta name="theme-color" content="#000000" />
      <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
      <meta name="apple-mobile-web-app-capable" content="yes" />
      <meta name="apple-mobile-web-app-status-bar-style" content="default" />
      <meta name="apple-mobile-web-app-title" content="大福映画 Felina Gallery" />
    </head>
    <body>
    <IntlProvider>
      <ConfigStoreProvider>
        <ButtonStoreProvider>
          <ThemeProvider>
            <ToasterProviders/>
            <ProgressBarProviders>
              {children}
              {modal}
            </ProgressBarProviders>
          </ThemeProvider>
        </ButtonStoreProvider>
      </ConfigStoreProvider>
    </IntlProvider>
    <div id="modal-root" />
    <Script
      id="umami-analytics"
      strategy="afterInteractive"
      async
      src={umamiHost}
      data-website-id={umamiAnalytics}
    />
    </body>
    </html>
  )
}