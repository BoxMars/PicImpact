import { AppSidebar } from '~/components/layout/admin/app-sidebar'
import { SidebarProvider, SidebarTrigger } from '~/components/ui/sidebar'
import { fetchSiteBranding } from '~/server/db/query/configs'

export default async function AdminLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const branding = await fetchSiteBranding()

  return (
    <SidebarProvider>
      <AppSidebar logoUrl={branding.logoUrl} siteTitle={branding.title} />
      <main className="flex w-full h-full flex-1 flex-col p-4">
        <SidebarTrigger className="cursor-pointer" />
        <div className="w-full h-full p-2">
          {children}
        </div>
      </main>
    </SidebarProvider>
  )
}
