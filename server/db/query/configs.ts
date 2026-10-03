// 配置表

import { unstable_cache } from 'next/cache'
import { db } from '~/server/lib/db'
import type { Config } from '~/types'

/**
 * 配置读取的缓存标签。任何写配置的地方都必须调用 `revalidateTag(CONFIGS_TAG)`，
 * 否则管理端最长 5 分钟看不到自己刚保存的值（见 `server/db/operate/configs.ts`）。
 */
export const CONFIGS_TAG = 'configs'

/**
 * 配置表极少变动，但此前每次请求都要查 2~3 遍（`generateMetadata` 一次、根 layout 一次、
 * 页面里再一次），每次都是一趟到东京的往返。
 *
 * 用 `unstable_cache` 跨请求缓存（带 tag，写入时失效）；调用参数会进入缓存键，
 * 所以不同 key 组合各自缓存。
 *
 * 注：本模块原先带 `'use server'`，现在改成普通服务端模块 —— 所有引用方都在服务端
 * （已逐一核对：页面 / layout / Hono 路由 / rss 路由），没有客户端组件直接 import；
 * 页面传给客户端的是它们自己定义的 `'use server'` 闭包，不依赖本模块的指令。
 * 去掉该指令是为了让 `unstable_cache` 与 Server Action 的"导出必须是 async 函数"
 * 约束不冲突。
 *
 * @param keys key 列表
 * @return {Promise<Config[]>} 配置列表
 */
export const fetchConfigsByKeys = unstable_cache(
  async (keys: string[]): Promise<Config[]> => {
    return await db.configs.findMany({
      where: {
        config_key: {
          in: keys
        }
      },
      select: {
        id: true,
        config_key: true,
        config_value: true,
        detail: true
      }
    })
  },
  ['configs-by-keys'],
  { revalidate: 300, tags: [CONFIGS_TAG] },
)

export type SiteBranding = {
  title: string
  logoUrl: string
}

/**
 * 获取站点品牌配置（标题和 Logo）。
 * Logo 优先使用 custom_logo_url，不存在时回退到 custom_favicon_url。
 */
export async function fetchSiteBranding(): Promise<SiteBranding> {
  const data = await fetchConfigsByKeys([
    'custom_title',
    'custom_logo_url',
    'custom_favicon_url',
  ])

  const title = data.find((item) => item.config_key === 'custom_title')?.config_value || '大福映画 Felina Gallery'
  const customLogoUrl = data.find((item) => item.config_key === 'custom_logo_url')?.config_value
  const customFaviconUrl = data.find((item) => item.config_key === 'custom_favicon_url')?.config_value

  return {
    title,
    logoUrl: customLogoUrl || customFaviconUrl || '/favicon.svg',
  }
}

/**
 * 根据 key 获取单个配置值
 * @param key 配置键
 * @param defaultValue 默认值
 * @return {Promise<string>} 配置值
 */
export const fetchConfigValue = unstable_cache(
  async (key: string, defaultValue: string = ''): Promise<string> => {
    const config = await db.configs.findFirst({
      where: {
        config_key: key
      },
      select: {
        config_value: true
      }
    })
    return config?.config_value || defaultValue
  },
  ['config-value'],
  { revalidate: 300, tags: [CONFIGS_TAG] },
)
