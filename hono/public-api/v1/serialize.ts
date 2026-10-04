/**
 * 注意：本文件**刻意不加** `import 'server-only'`。
 * 它是纯映射函数（不含任何密钥或服务端专属逻辑），而契约校验脚本
 * `scripts/api/verify-contract.ts` 必须在普通 Node 下导入它。
 * `server-only` 在非 react-server 条件下会直接抛错，加在这里等于让契约测试无法运行 ——
 * 这比"少一层误用保护"的代价大得多。同类先例：server/lib/preview-storage.ts。
 */

import type { AlbumType, ExifType, ImageType } from '~/types'

/**
 * ============================================================================
 * 公开 API v1 —— DTO 契约（冻结）
 * ============================================================================
 *
 * 这里是「旧版 App 兼容性」的实现点，改动前请先读 docs/superpowers/api/public-api-v1.md。
 *
 * 规则（违反任何一条都会悄悄打断已发布的 App）：
 *   1. **只能增加** 可选字段。绝不删除、改名、改变字段语义或类型。
 *   2. 数据库 / Prisma 模型怎么演进都可以 —— 只要在本文件里把值映射回下面的形状。
 *      例如将来把 `preview_url` 改名成 `thumb_url`，就在 `toImageDTOv1` 里写
 *      `previewUrl: image.thumb_url`，v1 的输出保持不变。
 *   3. 需要破坏性变更时，**新增 `/v2`**，不要动 v1。
 *   4. 改完跑 `pnpm api:verify-contract`，它会比对冻结的字段集合。
 *
 * 命名约定：对外用 camelCase（对 Swift 友好），与库内的 snake_case 解耦。
 */

/** 图片 DTO v1 */
export interface ImageDTOv1 {
  id: string
  /** 原始文件名（客户端保存到相册时用作文件名） */
  imageName: string
  /** 原图 URL */
  url: string
  /** 800px 缩略图 URL（列表一律用它，详见 docs 中的「图片加载」） */
  previewUrl: string
  /** Live Photo 的视频 URL */
  videoUrl: string
  /** 占位模糊图（blurhash 字符串，需要客户端解码） */
  blurhash: string
  width: number
  height: number
  title: string
  detail: string
  /** 1 = 普通图片，2 = Live Photo */
  type: number
  /** 标签数组；库里是 json，这里统一归一化为 string[] */
  labels: string[]
  /**
   * 经纬度。数据库列类型就是字符串（不是 number），**保持字符串**：
   * 一来避免浮点精度差异，二来避免旧数据里的空值导致解码失败。
   */
  lon: string
  lat: string
  /**
   * EXIF 原样透传（不做字段白名单）。
   * 客户端只取自己需要的字段，未知字段必须忽略 —— 这样服务端新增 EXIF 字段不需要发新版。
   */
  exif: ExifType | null
  /** 图片所属相册的许可协议。卡片下载/分享的提示文案会用到（见 gallery-image.tsx） */
  albumLicense: string | null
  /** ISO 8601（UTC）。为 null 表示历史数据缺失 */
  createdAt: string | null
}

/** 相册 DTO v1 */
export interface AlbumDTOv1 {
  id: string
  name: string
  /** 形如 `/daily`。客户端请求图片列表时作为 `album` 参数回传 */
  value: string
  detail: string | null
  /**
   * Web 端的画廊主题，`'0' | '1' | '2'`。
   * **iOS 端刻意忽略此字段**（只做 ACNH 岛屿卡一种呈现），此处保留仅为契约完整性，
   * 避免将来若要支持时又得加一个新字段。
   */
  theme: string
  license: string | null
}

/** 归一化标签：库里可能是数组、null、或历史脏数据 */
function normalizeLabels(labels: unknown): string[] {
  if (!Array.isArray(labels)) return []
  return labels.filter((v): v is string => typeof v === 'string')
}

/**
 * 时间归一化为 ISO 8601 字符串。
 * Prisma 的 DateTime 到 JSON 会自动变成 ISO，但原始 SQL 查询（$queryRaw）返回的是
 * Date 对象，两条路径都可能出现，这里统一处理，避免 DTO 类型漂移。
 */
function toISO(value: unknown): string | null {
  if (!value) return null
  if (value instanceof Date) return value.toISOString()
  const d = new Date(String(value))
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}

/** 站点配置 DTO v1 */
export interface SiteConfigDTOv1 {
  apiVersion: string
  /** 客户端翻页用；不要硬编码 */
  pageSize: number
  site: {
    title: string
    author: string
    logoUrl: string
    faviconUrl: string
    /** 首页画廊风格：'0' | '1' | '2'。iOS 只实现 '1'（ACNH 岛屿卡） */
    indexStyle: string
  }
  /** 能力协商：App 依据这里的开关决定显示哪些功能，而不是猜版本号 */
  features: {
    download: boolean
    origin: boolean
    toneAnalysis: boolean
    livePhoto: boolean
    map: boolean
  }
}

export interface ConfigRow {
  config_key: string
  config_value: string | null
}

/**
 * ⚠️ 布尔语义**必须与 Web 端完全一致**：Web 判的是
 * `config_value.toString() === 'true'`（见 components/gallery/simple/gallery-image.tsx:274），
 * 数据库里存的就是字符串 `"true"` / `"false"`，**不是** `"1"` / `"0"`。
 * 曾经我把这里写成 `=== '1'`，结果生产实际已开启下载（值为 "true"）却对外报告 download:false，
 * 会让 App 错误地隐藏下载入口。（`custom_index_style` 才是 '0'/'1'/'2' 的枚举。）
 */
const isEnabled = (rows: ConfigRow[] | undefined, key: string): boolean =>
  rows?.find((r) => r.config_key === key)?.config_value === 'true'

export function toSiteConfigDTOv1(
  rows: ConfigRow[] | undefined,
  apiVersion: string,
  pageSize: number
): SiteConfigDTOv1 {
  const text = (key: string) => rows?.find((r) => r.config_key === key)?.config_value ?? ''
  return {
    apiVersion,
    pageSize,
    site: {
      title: text('custom_title'),
      author: text('custom_author'),
      logoUrl: text('custom_logo_url'),
      faviconUrl: text('custom_favicon_url'),
      indexStyle: text('custom_index_style'),
    },
    features: {
      download: isEnabled(rows, 'custom_index_download_enable'),
      origin: isEnabled(rows, 'custom_index_origin_enable'),
      toneAnalysis: true,
      livePhoto: true,
      map: true,
    },
  }
}

export function toImageDTOv1(image: ImageType): ImageDTOv1 {
  return {
    id: image.id,
    imageName: image.image_name ?? '',
    url: image.url ?? '',
    previewUrl: image.preview_url ?? '',
    videoUrl: image.video_url ?? '',
    blurhash: image.blurhash ?? '',
    width: image.width ?? 0,
    height: image.height ?? 0,
    title: image.title ?? '',
    detail: image.detail ?? '',
    type: image.type ?? 1,
    labels: normalizeLabels(image.labels),
    lon: image.lon ?? '',
    lat: image.lat ?? '',
    exif: (image.exif ?? null) as ExifType | null,
    albumLicense: image.album_license ?? null,
    createdAt: toISO((image as unknown as { created_at?: unknown }).created_at),
  }
}

export function toAlbumDTOv1(album: AlbumType): AlbumDTOv1 {
  return {
    id: album.id,
    name: album.name ?? '',
    value: album.album_value ?? '',
    detail: album.detail ?? null,
    theme: album.theme ?? '0',
    license: album.license ?? null,
  }
}

/**
 * 所有序列化器的集合。契约校验脚本（scripts/api/verify-contract.ts）会遍历它，
 * 对冻结的字段集合做比对 —— 所以**新增序列化器时记得同时更新 fixture**。
 */
export const V1_SERIALIZERS = {
  image: toImageDTOv1,
  album: toAlbumDTOv1,
  config: toSiteConfigDTOv1,
} as const
