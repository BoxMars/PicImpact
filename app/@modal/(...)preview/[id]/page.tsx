import { Modal } from './modal.tsx'
import PreView from '~/app/(default)/preview/[...id]/page'

/**
 * 必须保持动态渲染。
 * 该页依赖鉴权/用户态：一旦被静态化并进入边缘缓存，边缘会在**不调用函数与中间件**
 * 的情况下直接返回缓存内容，从而把非公开数据暴露给未登录访客。
 */
export const dynamic = 'force-dynamic'

export default async function Page({params}: { params: any }) {
  return (
    <Modal>
      <PreView params={params} />
    </Modal>
  )
}