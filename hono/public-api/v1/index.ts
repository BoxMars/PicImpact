import 'server-only'

import { Hono } from 'hono'

import { fetchAlbumsShow } from '~/server/db/query/albums'
import { fetchConfigsByKeys } from '~/server/db/query/configs'
import {
  fetchAllTags,
  fetchClientCameraAndLensList,
  fetchClientImagesListByAlbum,
  fetchClientImagesListByTag,
  fetchClientImagesPageTotalByAlbum,
  fetchClientImagesPageTotalByTag,
  fetchImageByIdAndAuth,
} from '~/server/db/query/images'
import type { ImageType } from '~/types'

import { PAGE_SIZE, apiHeaders, ok, parsePage, type ApiEnvelope } from '../shared'
import {
  toAlbumDTOv1,
  toImageDTOv1,
  toSiteConfigDTOv1,
  type AlbumDTOv1,
  type ImageDTOv1,
  type SiteConfigDTOv1,
} from './serialize'

const VERSION = 'v1' as const

/** 站点配置里对客户端可见的键（其余配置属于后台，不对外暴露） */
const PUBLIC_CONFIG_KEYS = [
  'custom_title',
  'custom_author',
  'custom_logo_url',
  'custom_favicon_url',
  // 注意别漏：曾漏掉 index_style，导致取值函数拿不到该键、静默返回空串
  'custom_index_style',
  'custom_index_download_enable',
  'custom_index_origin_enable',
] as const

const app = new Hono()

/** 版本自述：便于排查「App 实际拿到的是哪个版本」 */
app.get('/', (c) =>
  c.json(
    ok({
      apiVersion: VERSION,
      endpoints: ['/config', '/albums', '/tags', '/filters', '/images', '/images/:id'],
      pageSize: PAGE_SIZE,
    }),
    200,
    apiHeaders(VERSION)
  )
)

/**
 * 契约元信息 + 站点配置。
 *
 * 客户端**必须先请求这个接口**：它同时承担「能力协商」职责 —— App 依据 `features`
 * 决定显示哪些功能，而不是硬编码版本号去猜。服务端新增能力只需往 `features` 加键，
 * 旧版 App 会自然忽略未知键（前向兼容）。
 */
app.get('/config', async (c) => {
  const rows = await fetchConfigsByKeys([...PUBLIC_CONFIG_KEYS])
  const data: ApiEnvelope<SiteConfigDTOv1> = ok(toSiteConfigDTOv1(rows, VERSION, PAGE_SIZE))
  return c.json(data, 200, apiHeaders(VERSION))
})

/** 公开相册列表（服务端已过滤 show=0 且 del=0，并排除首页用的 `/`） */
app.get('/albums', async (c) => {
  const albums = await fetchAlbumsShow()
  const data: ApiEnvelope<AlbumDTOv1[]> = ok(albums.map(toAlbumDTOv1))
  return c.json(data, 200, apiHeaders(VERSION))
})

/** 全部标签（去重、升序） */
app.get('/tags', async (c) => {
  const tags = await fetchAllTags()
  return c.json(ok(tags), 200, apiHeaders(VERSION))
})

/** 相机 / 镜头筛选值（用于复刻 Web 端的筛选控件）。不传 `album` 时返回全部。 */
app.get('/filters', async (c) => {
  const album = c.req.query('album') || undefined
  const { cameras, lenses } = await fetchClientCameraAndLensList(album)
  return c.json(ok({ cameras, lenses }), 200, apiHeaders(VERSION))
})

/**
 * 单张图片。深链接（App 被 URL 唤起直接打开某张图）时无需先拉列表。
 * 只返回公开图片，语义与 Web 的 `/api/public/images/get-image-by-id` 一致。
 */
app.get('/images/:id', async (c) => {
  const id = c.req.param('id')
  // 该函数返回类型标注为非空，但运行时查不到时返回 undefined（见 hono/open/images.ts 的同类处理）
  const image = (await fetchImageByIdAndAuth(id)) as ImageType | undefined
  if (!image) {
    return c.json(
      { code: 404, message: 'image not found or not public', data: null },
      404,
      apiHeaders(VERSION)
    )
  }
  const data: ApiEnvelope<ImageDTOv1> = ok(toImageDTOv1(image))
  return c.json(data, 200, apiHeaders(VERSION))
})

/**
 * 图片列表。三种取法互斥，**优先级：tag > album**（显式传 tag 时忽略 album）。
 *
 *   /images                         → 首页（album 默认 `/`，即所有 show_on_mainpage=0 的图）
 *   /images?album=%2Fdaily          → 指定相册
 *   /images?tag=%E6%97%A5%E5%B8%B8  → 指定标签
 *
 * `camera` / `lens` 仅对 album 模式生效（与 Web 端行为一致）。
 * 分页大小固定 24，响应里回传 `pageSize`；`pageTotal` 是总**页数**（服务端就是这么算的）。
 */
app.get('/images', async (c) => {
  const page = parsePage(c.req.query('page'))
  const tag = c.req.query('tag')?.trim()
  const camera = c.req.query('camera')?.trim() || undefined
  const lens = c.req.query('lens')?.trim() || undefined

  if (tag) {
    const [list, pageTotal] = await Promise.all([
      fetchClientImagesListByTag(page, tag),
      fetchClientImagesPageTotalByTag(tag),
    ])
    return c.json(
      ok({
        list: list.map(toImageDTOv1),
        page,
        pageSize: PAGE_SIZE,
        pageTotal,
        hasMore: page < pageTotal,
      }),
      200,
      apiHeaders(VERSION)
    )
  }

  // 与 Web 端一致：不传 album 即首页
  const album = c.req.query('album')?.trim() || '/'
  const [list, pageTotal] = await Promise.all([
    fetchClientImagesListByAlbum(page, album, camera, lens),
    fetchClientImagesPageTotalByAlbum(album, camera, lens),
  ])

  return c.json(
    ok({
      list: list.map(toImageDTOv1),
      page,
      pageSize: PAGE_SIZE,
      pageTotal,
      hasMore: page < pageTotal,
      album,
    }),
    200,
    apiHeaders(VERSION)
  )
})

export default app
