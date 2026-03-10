import { UserFrom } from '~/components/login/user-from'
import Image from 'next/image'
import Link from 'next/link'
import { fetchSiteBranding } from '~/server/db/query/configs'

export default async function Login() {
  const branding = await fetchSiteBranding()

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted p-6 md:p-10">
      <div className="flex w-full max-w-sm flex-col gap-6">
        <Link href="/" className="flex items-center gap-2 self-center font-medium select-none">
          <div className="flex h-6 w-6 items-center justify-center rounded-lg overflow-hidden">
            <Image
              src={branding.logoUrl}
              alt="Logo"
              width={36}
              height={36}
              className="h-9 w-9 rounded-lg object-cover"
              unoptimized
            />
          </div>
          {branding.title}
        </Link>
        <UserFrom/>
      </div>
    </div>
  )
}
