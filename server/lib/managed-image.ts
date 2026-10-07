import { fetchConfigsByKeys } from '~/server/db/query/configs'
import { normalizeExifDateTime } from '~/lib/utils/exif-time'
import {
  R2_CONFIG_KEYS,
  S3_CONFIG_KEYS,
  ensureManagedPreviewUrl,
  resolveStorageTargets,
} from '~/server/lib/preview-storage'

/**
 * 入库前补齐**图像派生**的元数据：`preview_url` / `width` / `height` / `blurhash`。
 *
 * ## 为什么抽出来单独一个模块
 * 这段逻辑原本内联在 `hono/images.ts` 里（web 上传走 `POST /api/v1/images/add`）。
 * 现在 App 的登记接口（`POST /api/v1/admin/images`）也必须走**同一套**处理，
 * 否则同一张原图在 web 与 App 上会得到不同的预览图/宽高/blurhash（Review Focus 3）。
 * 抄第二遍必然会漂移，所以只留这一份。
 *
 * ## 规则（Review Focus 4 的裁决）
 * 预览图与 blurhash 都归**服务端**：客户端（web 与 iOS）只上传原图 + 送元数据。
 * 客户端传的 `preview_url` / `blurhash` / `width` / `height` 只是兜底 —— 服务端算得出来就覆盖。
 *
 * 失败**不阻断入库**：存储瞬时故障不该让整次上传白做。失败会打日志，
 * 并可由 `pnpm migrate:regenerate-previews` 回填。
 */
export async function attachManagedImageMetadata(body: Record<string, any>): Promise<void> {
  // 兼容并规范化 EXIF 拍摄时间（原本在 hono/images.ts 里做，一起收进来）
  if (body?.exif) {
    const normalizedCaptureTime = normalizeExifDateTime(body?.exif?.data_time || body?.exif?.date_time || '')
    body.exif.data_time = normalizedCaptureTime
  }

  if (!body?.url) return

  try {
    const configs = await fetchConfigsByKeys([...R2_CONFIG_KEYS, ...S3_CONFIG_KEYS])
    const targets = resolveStorageTargets(configs)
    const result = await ensureManagedPreviewUrl(body.url, targets)

    if (!result.ok) {
      console.warn(`[preview] 未能生成受管缩略图，入库继续：${result.reason}`)
      return
    }

    body.preview_url = result.previewUrl
    if (result.originalWidth > 0 && result.originalHeight > 0) {
      body.width = result.originalWidth
      body.height = result.originalHeight
    }
    // blurhash 也是服务端权威值（客户端那份若存在会被覆盖）
    body.blurhash = result.blurhash

    const ratio = ((1 - result.previewBytes / result.originalBytes) * 100).toFixed(1)
    console.log(
      `[preview] ${result.originalBytes}B → ${result.previewBytes}B (−${ratio}%) ` +
        `缩略图 ${result.width}x${result.height}，原图显示尺寸 ${result.originalWidth}x${result.originalHeight}`,
    )
  } catch (e) {
    console.warn('[preview] 生成缩略图抛错，入库继续：', e)
  }
}
