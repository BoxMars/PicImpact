import { fetchMapImages } from '~/server/db/query/images'
import { MapView } from '~/components/layout/theme/map/map-view'
import { fetchConfigsByKeys } from '~/server/db/query/configs'

/**
 * ISR：本页内容对所有访客一致且无需鉴权，可进 Vercel 边缘缓存。
 * 原先因根 layout 读 cookie 而永远动态渲染（x-vercel-cache: MISS）。
 * 图片写入时会调用 revalidateTag('images')，正常情况下新照片立即出现；
 * 60 秒是兜底，避免标签失效未覆盖到路由缓存时长期不更新。
 */
export const revalidate = 60

export async function generateMetadata() {
  const data = await fetchConfigsByKeys(['custom_title'])
  const siteTitle = data?.find(item => item.config_key === 'custom_title')?.config_value || '大福映画 Felina Gallery'
  return {
    title: `Map | ${siteTitle}`,
  }
}

export default async function MapPage() {
  const images = await fetchMapImages()

  return (
    <div className="w-full h-screen">
      <MapView images={images} />
    </div>
  )
}
