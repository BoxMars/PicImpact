// 相册表

import { unstable_cache } from 'next/cache'
import { db } from '~/server/lib/db'
import type { AlbumType } from '~/types'

/**
 * 相册读取的缓存标签。写相册的地方必须 `revalidateTag(ALBUMS_TAG)`
 * （见 `server/db/operate/albums.ts`）。
 */
export const ALBUMS_TAG = 'albums'

/**
 * 获取所有相册列表
 *
 * `fetchAlbumsShow` 此前在三个 route-group layout 里各被调用一次
 * （`(default)` / `(theme)/[...album]` / `(theme)/map`），每次都是一趟到东京的往返。
 * 相册列表变动频率很低，加 `unstable_cache` 后跨请求复用，写入时用 tag 失效。
 */
export const fetchAlbumsList = unstable_cache(
  async (): Promise<AlbumType[]> => {
    return await db.albums.findMany({
      where: {
        del: 0
      },
      orderBy: [
        {
          sort: 'desc',
        },
        {
          createdAt: 'desc',
        },
        {
          updatedAt: 'desc'
        }
      ]
    })
  },
  ['albums-list'],
  { revalidate: 300, tags: [ALBUMS_TAG] },
)

/**
 * 获取所有能显示的相册列表（除了首页路由外
 */
export const fetchAlbumsShow = unstable_cache(
  async (): Promise<AlbumType[]> => {
    return await db.albums.findMany({
      where: {
        del: 0,
        show: 0,
        album_value: {
          not: '/'
        }
      },
      orderBy: [
        {
          sort: 'desc'
        }
      ]
    })
  },
  ['albums-show'],
  { revalidate: 300, tags: [ALBUMS_TAG] },
)

/**
 * 获取对应路由的相册信息
 * @param router 相册路由
 */
export const fetchAlbumByRouter = unstable_cache(
  async (router: string): Promise<AlbumType> => {
    return await db.albums.findFirst({
      where: {
        del: 0,
        show: 0,
        album_value: router
      },
    }) as Promise<AlbumType>
  },
  ['album-by-router'],
  { revalidate: 300, tags: [ALBUMS_TAG] },
)
