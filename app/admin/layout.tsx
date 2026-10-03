import { AppSidebar } from '~/components/layout/admin/app-sidebar'
import { SidebarProvider, SidebarTrigger } from '~/components/ui/sidebar'
import { fetchSiteBranding } from '~/server/db/query/configs'
import { NextIntlClientProvider } from 'next-intl'
import { getLocale, getMessages } from 'next-intl/server'

/**
 * 管理端整段强制动态渲染（在 layout 上声明，覆盖其下所有路由）。
 *
 * 两个原因，缺一不可：
 * 1. 鉴权只由 `proxy.ts` 中间件完成。**边缘缓存会在不调用函数/中间件的情况下直接
 *    返回缓存响应**，所以任何被静态化/缓存的 /admin 页面都可能绕过鉴权被未登录访客拿到。
 * 2. 管理端需要"按 cookie 选语言"，而读 cookie 本身就要求动态渲染（公开页已不再读，
 *    见 app/layout.tsx 的说明）。
 */
export const dynamic = 'force-dynamic'

export default async function AdminLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const branding = await fetchSiteBranding()

  // 只有这里（以及它下面的路由）会读 NEXT_LOCALE cookie
  const locale = await getLocale()
  const messages = await getMessages()

  return (
    <NextIntlClientProvider locale={locale} messages={messages} timeZone="Asia/Shanghai">
    <SidebarProvider>
      <AppSidebar logoUrl={branding.logoUrl} siteTitle={branding.title} />
      <main className="flex w-full h-full flex-1 flex-col p-4">
        <SidebarTrigger className="cursor-pointer" />
        <div className="w-full h-full p-2">
          {children}
        </div>
      </main>
    </SidebarProvider>
    </NextIntlClientProvider>
  )
}
