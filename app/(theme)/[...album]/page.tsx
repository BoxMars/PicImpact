import { fetchClientImagesListByAlbum, fetchClientImagesPageTotalByAlbum } from '~/server/db/query/images.ts'
import type { ImageHandleProps } from '~/types/props.ts'
import { fetchConfigsByKeys } from '~/server/db/query/configs.ts'
import { fetchAlbumByRouter, fetchAlbumsShow } from '~/server/db/query/albums.ts'
import dynamic from 'next/dynamic'
import 'react-photo-album/masonry.css'
import type { AlbumType, Config } from '~/types'

// 三种画廊按相册的 `theme` 运行时选一种，但此前是**静态** import —— 三种的客户端代码
// 都会进首屏包（连带 react-photo-album / motion）。改成 dynamic 后服务端仍渲染命中的
// 那一种（next/dynamic 默认保留 ssr，首屏 HTML 不缺内容），客户端只请求用到的 chunk。
const SimpleGallery = dynamic(() => import('~/components/layout/theme/simple/simple-gallery'))
const DefaultGallery = dynamic(() => import('~/components/layout/theme/default/default-gallery'))
const PolaroidGallery = dynamic(() => import('~/components/layout/theme/polaroid/polaroid-gallery'))

const ALBUM_CONFIG_KEYS = ['custom_index_download_enable']

/**
 * ISR：本页内容对所有访客一致且无需鉴权，可进 Vercel 边缘缓存。
 * 原先因根 layout 读 cookie 而永远动态渲染（x-vercel-cache: MISS）。
 * 图片写入时会调用 revalidateTag('images')，正常情况下新照片立即出现；
 * 60 秒是兜底，避免标签失效未覆盖到路由缓存时长期不更新。
 */
export const revalidate = 60

/**
 * 动态路由段必须提供 generateStaticParams，Next 才会在构建期预渲染这些路径并给出
 * 可缓存的响应头。否则即使声明了 `revalidate`，响应仍是
 * `Cache-Control: private, no-cache, no-store`（实测），边缘无法缓存。
 *
 * `[...album]` 是 catch-all 段，因此参数以数组形式返回。
 */
export async function generateStaticParams() {
  const albums = await fetchAlbumsShow()
  return albums
    .map((a) => a.album_value?.replace(/^\//, ''))
    .filter((v): v is string => Boolean(v))
    .map((album) => ({ album: [album] }))
}

export default async function Page({
  params
}: {
  params: Promise<{ album: string }>
}) {
  const { album } = await params
  const albumValue = `/${album}`

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
    return await fetchConfigsByKeys(ALBUM_CONFIG_KEYS)
  }

  // 此前这里只 await 了相册信息，没有 initialImages / initialPageTotal / initialConfigData，
  // 于是消费方的 `fallbackData` 全是 undefined —— 首屏只能吐一个空壳，水合之后还要再发
  // 2~3 个 server action 回源才拿到照片（双段瀑布，实测很像是"点了没反应然后突然跳出来"）。
  // 按首页的做法并行取好，并把相互独立的查询放进同一个 Promise.all。
  const [data, initialConfigData, initialImages, initialPageTotal] = await Promise.all([
    fetchAlbumByRouter(albumValue),
    getConfig(),
    getData(1, albumValue),
    getPageTotal(albumValue),
  ])

  const props: ImageHandleProps = {
    handle: getData,
    args: 'getImages-client',
    album: albumValue,
    totalHandle: getPageTotal,
    configHandle: getConfig,
    initialImages,
    initialPageTotal,
    initialConfigData: initialConfigData as Config[],
  }

  const theme = (data as AlbumType | undefined)?.theme

  return (
    <>
      {theme === '1' ? <SimpleGallery {...props} />
        : theme === '2' ? <PolaroidGallery {...props} />
          : <DefaultGallery {...props} />
      }
    </>
  )
}
