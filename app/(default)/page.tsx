import type { ImageHandleProps } from '~/types/props'
import { AppStoreBanner } from '~/components/layout/appstore-banner'
import { fetchClientImagesListByAlbum, fetchClientImagesPageTotalByAlbum } from '~/server/db/query/images'
import { fetchConfigsByKeys } from '~/server/db/query/configs'
import dynamic from 'next/dynamic'
import 'react-photo-album/masonry.css'
import type { Config } from '~/types'

// 三种画廊按 `custom_index_style` 运行时选一种，但此前是**静态** import —— 三种的
// 客户端代码都会进首屏包（连带 react-photo-album / motion）。改成 dynamic：
// 服务端仍会渲染命中的那一种（next/dynamic 默认 ssr 保持开启，首屏 HTML 不缺内容），
// 但客户端只会请求真正用到的那一份 chunk。
const SimpleGallery = dynamic(() => import('~/components/layout/theme/simple/simple-gallery'))
const DefaultGallery = dynamic(() => import('~/components/layout/theme/default/default-gallery'))
const PolaroidGallery = dynamic(() => import('~/components/layout/theme/polaroid/polaroid-gallery'))

/**
 * ISR：本页内容对所有访客一致且无需鉴权，可进 Vercel 边缘缓存。
 * 原先因根 layout 读 cookie 而永远动态渲染（x-vercel-cache: MISS）。
 * 图片写入时会调用 revalidateTag('images')，正常情况下新照片立即出现；
 * 60 秒是兜底，避免标签失效未覆盖到路由缓存时长期不更新。
 */
export const revalidate = 60

export default async function Home() {
  const getData = async (pageNum: number, album: string, camera?: string, lens?: string) => {
    'use server'
    return await fetchClientImagesListByAlbum(pageNum, album, camera, lens)
  }

  const getPageTotal = async (album: string, camera?: string, lens?: string) => {
    'use server'
    return await fetchClientImagesPageTotalByAlbum(album, camera, lens)
  }

  const getConfig = async () => {
    'use server'
    return await fetchConfigsByKeys([
      'custom_index_download_enable',
      'custom_index_origin_enable',
      'custom_title',
      'custom_index_style',
    ])
  }

  const initialConfigData: Config[] = await getConfig()
  const [initialImages, initialPageTotal] = await Promise.all([
    getData(1, '/'),
    getPageTotal('/'),
  ])
  const currentStyle = initialConfigData.find(a => a.config_key === 'custom_index_style')?.config_value

  const props: ImageHandleProps = {
    handle: getData,
    args: 'getImages-client',
    album: '/',
    totalHandle: getPageTotal,
    configHandle: getConfig,
    initialImages,
    initialPageTotal,
    initialConfigData,
  }

  return (
    <>
      {/* 顶部 App Store 横幅：使用官方徽章，链接为 Apple 查询接口返回的真实地址 */}
      <AppStoreBanner />
      {currentStyle
        && currentStyle === '1' ? <SimpleGallery {...props} />
        : currentStyle === '2' ? <PolaroidGallery {...props} />
        : <DefaultGallery {...props} />
      }
    </>
  )
}
