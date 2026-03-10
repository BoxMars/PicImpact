'use client'
import {
  DropdownMenu,
  DropdownMenuTrigger,
} from '~/components/ui/dropdown-menu'
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from '~/components/ui/sidebar'
import Image from 'next/image'
import { useRouter } from 'next-nprogress-bar'

type NavTitleProps = {
  logoUrl: string
  title: string
}

export function NavTitle({ logoUrl, title }: Readonly<NavTitleProps>) {
  const router = useRouter()

  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <SidebarMenuButton className="cursor-pointer select-none" size="lg" onClick={() => router.push('/')}>
              <div className="flex aspect-square size-8 items-center justify-center rounded-lg overflow-hidden">
                <Image src={logoUrl} alt="Logo" width={32} height={32} className="h-8 w-8 rounded-lg object-cover" unoptimized />
              </div>
              <div className="grid flex-1 text-left text-sm leading-tight">
                <span className="truncate font-semibold select-none">
                  {title || 'PicImpact'}
                </span>
              </div>
            </SidebarMenuButton>
          </DropdownMenuTrigger>
        </DropdownMenu>
      </SidebarMenuItem>
    </SidebarMenu>
  )
}
