import sharp from 'sharp'

/**
 * 服务端缩略图生成。
 *
 * 背景（实测 2026-10-03）：原实现的缩略图由浏览器端 Compressor.js 生成，而缩放被一个
 * 配置项挡住 —— 数据库里 `preview_max_width_limit_switch = 1`（开关开）但
 * `preview_max_width_limit = 0`（限制值为 0），代入
 * `maxWidth: switchOn && limit > 0 ? limit : undefined` 得到 `undefined`，
 * 于是 Compressor **只重编码、从不缩放**。实测结果：`preview_url` 指向的 webp 与
 * 原图**像素尺寸完全相同**（4032×3024），只是字节更小；还有 2 张因 webp 编码回落
 * 变成了 12MP 的 PNG（21.76MB / 14.12MB）。
 *
 * 因此缩略图职责收归服务端，用 sharp 显式缩放，不再依赖任何配置开关。
 */

/**
 * 缩略图最长边。
 *
 * 取 800 而非 400：网格在 1280px 容器下是 3 列（`33vw` ≈ 420 CSS px），
 * 2x DPR 需要约 840 物理像素，800 是接近的最优值 —— 再小在视网膜屏上会发虚。
 */
export const THUMBNAIL_MAX_EDGE = 800

/** webp 质量。76 在照片类内容上是"看不出差别但明显更小"的常用拐点。 */
export const THUMBNAIL_QUALITY = 76

export type Thumbnail = {
  buffer: Buffer
  width: number
  height: number
  contentType: 'image/webp'
  ext: 'webp'
}

/**
 * 从原图字节生成缩略图。
 *
 * - `.rotate()` 无参调用会**应用** EXIF 方向并清除该标记，顺带修掉原实现
 *   `checkOrientation: false` 造成的宽高互换问题。
 * - `fit: 'inside'` + `withoutEnlargement` 保证小图不被放大。
 * - 输出必须是 webp；编码结果不是 webp 时**显式报错**，绝不回落成 PNG/JPEG
 *   （那正是 21.76MB "缩略图" 的成因）。
 */
export async function generateThumbnail(input: Buffer | Uint8Array): Promise<Thumbnail> {
  const { data, info } = await sharp(input, { failOn: 'none' })
    .rotate()
    .resize({
      width: THUMBNAIL_MAX_EDGE,
      height: THUMBNAIL_MAX_EDGE,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .webp({ quality: THUMBNAIL_QUALITY })
    .toBuffer({ resolveWithObject: true })

  if (info.format !== 'webp') {
    throw new Error(`缩略图编码失败：期望 webp，实际得到 ${info.format}`)
  }

  return {
    buffer: data,
    width: info.width,
    height: info.height,
    contentType: 'image/webp',
    ext: 'webp',
  }
}

/**
 * 由原图 object key 推导缩略图 key，沿用既有目录约定 `<dir>/preview/<name>.webp`。
 *
 * 例：`images/daily/abc.jpeg` → `images/daily/preview/<newName>.webp`
 */
export function buildPreviewKey(originalKey: string, newName: string): string {
  const slash = originalKey.lastIndexOf('/')
  const dir = slash === -1 ? '' : originalKey.slice(0, slash)
  return dir ? `${dir}/preview/${newName}.webp` : `preview/${newName}.webp`
}

/**
 * 判断一个 `preview_url` 是否合格，供迁移脚本报告使用。
 *
 * 注意：这**只做便宜的形态检查**（非空、不等于原图、且在 preview 目录且为 webp）。
 * 它无法判断像素尺寸是否真的被缩放过 —— 实测中"合格形态但仍是 4032×3024"正是原缺陷，
 * 所以迁移脚本按 spec R1.2 的裁决**无条件重生全部行**，不依赖本函数做跳过判断。
 */
export function looksLikeManagedPreview(previewUrl: string | null | undefined, url: string | null | undefined): boolean {
  if (!previewUrl) return false
  if (!url || previewUrl === url) return false
  if (!/\/preview\//.test(previewUrl)) return false
  return /\.webp$/i.test(previewUrl)
}
