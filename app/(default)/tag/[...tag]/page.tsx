import type { ImageHandleProps } from '~/types/props'
import { fetchAllTags, fetchClientImagesListByTag, fetchClientImagesPageTotalByTag } from '~/server/db/query/images'
import TagGallery from '~/components/album/tag-gallery'

import 'react-photo-album/masonry.css'

/**
 * ISR：本页内容对所有访客一致且无需鉴权，可进 Vercel 边缘缓存。
 * 原先因根 layout 读 cookie 而永远动态渲染（x-vercel-cache: MISS）。
 * 图片写入时会调用 revalidateTag('images')，正常情况下新照片立即出现；
 * 60 秒是兜底，避免标签失效未覆盖到路由缓存时长期不更新。
 */
export const revalidate = 60

/**
 * 与 `/[album]` 同理：动态段必须给出具体路径，`revalidate` 才会生效
 * （否则响应是 `private, no-cache, no-store`）。`[...tag]` 是 catch-all，
 * 参数以数组返回。新增标签仍可按需渲染（dynamicParams 默认 true）。
 */
export async function generateStaticParams() {
  const tags = await fetchAllTags()
  return tags.map((tag) => ({ tag: [tag] }))
}

export default async function Label({params}: { params: any }) {
  const { tag } = await params
  const decodedTag = decodeURIComponent(tag)

  const getData = async (pageNum: number, tag: string, _camera?: string, _lens?: string) => {
    'use server'
    // Tag gallery doesn't use camera/lens filters
    return await fetchClientImagesListByTag(pageNum, tag)
  }

  const getPageTotal = async (tag: string, _camera?: string, _lens?: string) => {
    'use server'
    // Tag gallery doesn't use camera/lens filters
    return await fetchClientImagesPageTotalByTag(tag)
  }

  const getConfig = async () => {
    'use server'
    return []
  }

  const [initialImages, initialPageTotal] = await Promise.all([
    getData(1, decodedTag),
    getPageTotal(decodedTag),
  ])

  const props: ImageHandleProps = {
    handle: getData,
    args: 'getImages-client-tag',
    album: decodedTag,
    totalHandle: getPageTotal,
    configHandle: getConfig,
    initialImages,
    initialPageTotal,
    initialConfigData: [],
  }

  return (
    <TagGallery {...props} />
  )
}
