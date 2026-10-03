import { fetchImageByIdAndAuth } from '~/server/db/query/images'
import type { PreviewImageHandleProps } from '~/types/props'
import PreviewImage from '~/components/album/preview-image'
import { fetchConfigsByKeys } from '~/server/db/query/configs'

/**
 * 必须保持动态渲染。
 * 该页依赖鉴权/用户态：一旦被静态化并进入边缘缓存，边缘会在**不调用函数与中间件**
 * 的情况下直接返回缓存内容，从而把非公开数据暴露给未登录访客。
 */
export const dynamic = 'force-dynamic'

export default async function PreView({params}: { params: any }) {
  const { id } = await params

  const getData = async (id: string) => {
    'use server'
    return await fetchImageByIdAndAuth(String(id))
  }

  const getConfig = async () => {
    'use server'
    return await fetchConfigsByKeys([
      'custom_index_download_enable',
      'custom_author',
    ])
  }

  const imageData = await getData(id)

  const props: PreviewImageHandleProps = {
    data: imageData,
    args: 'getImages-client-preview',
    id: id,
    configHandle: getConfig,
  }

  return (
    <PreviewImage {...props} />
  )
}
