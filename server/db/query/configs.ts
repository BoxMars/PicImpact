// 配置表

'use server'

import { db } from '~/server/lib/db'
import type { Config } from '~/types'

/**
 * 根据 key 获取配置
 * @param keys key 列表
 * @return {Promise<Config[]>} 配置列表
 */
export async function fetchConfigsByKeys(keys: string[]): Promise<Config[]> {
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
}

export type SiteBranding = {
  title: string
  logoUrl: string
}

/**
 * 获取站点品牌配置（标题和 Logo）
 * Logo 优先使用 custom_logo_url，不存在时回退到 custom_favicon_url。
 */
export async function fetchSiteBranding(): Promise<SiteBranding> {
  const data = await fetchConfigsByKeys([
    'custom_title',
    'custom_logo_url',
    'custom_favicon_url',
  ])

  const title = data.find((item) => item.config_key === 'custom_title')?.config_value || 'PicImpact'
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
export async function fetchConfigValue(key: string, defaultValue: string = ''): Promise<string> {
  const config = await db.configs.findFirst({
    where: {
      config_key: key
    },
    select: {
      config_value: true
    }
  })
  return config?.config_value || defaultValue
}
