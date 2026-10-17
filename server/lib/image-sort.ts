/**
 * 图片列表的排序片段（公开 API 的 `sort` 参数与首页/相册默认值都从这里取）。
 *
 * ## 为什么单独一个文件
 * 这些是**纯字符串**（SQL 片段）与一个纯函数 `parseImageSort`，不该被 `server/db/query/images.ts`
 * 的 Prisma / `next/cache` 依赖绑住 —— 抽出来以后能在 `node --test` 下直接断言，
 * 与 `server/lib/admin-api.ts`、`server/lib/push-api.ts` 是同一个理由。
 *
 * ## 术语（与 Web 后台既有说法对齐）
 * - **上传时间** = `images.created_at`（入库时间）—— 不是"发布时间"这种第三种说法
 * - **拍摄时间** = EXIF 的 `data_time` / `date_time`
 *
 * 对应文案：`messages/zh.json` 的 `Album.uploadTimeNewToOld` 等四条。
 */

/**
 * EXIF 拍摄时间的排序表达式：取不到就回落到 1970（= 排到最后）。
 *
 * 这是派生表达式、**无法走索引**；能索引的部分（可见性 + sort/created_at）由
 * `20261003130000_add_gallery_indexes` 那批部分索引覆盖。
 */
export const EXIF_CAPTURE_TIME_SQL =
  'COALESCE(TO_TIMESTAMP(COALESCE(image.exif->>\'data_time\', image.exif->>\'date_time\'), \'YYYY:MM:DD HH24:MI:SS\'), \'1970-01-01 00:00:00\')'

/**
 * 首页默认排序：**拍摄时间从新到旧**。
 *
 * ⚠️ 它与相册排序规则 2 是**同一条**（曾经在代码里逐字写了两遍，实测 183 字符完全一致）。
 * 现在只留一份：`ALBUM_IMAGE_SORTING_ORDER[2]` 直接引用它。
 */
export const HOME_IMAGE_SORTING_ORDER = `${EXIF_CAPTURE_TIME_SQL} DESC, image.created_at DESC, image.updated_at DESC`

/**
 * 公开 API `sort` 参数 → 排序片段（**不含**前导的 `image.sort DESC,`，那个人工置顶永远在最前面）。
 *
 * 为什么末尾都补一个 `image.id`：`created_at` / `updated_at` 都**不唯一**
 * （批量上传同一秒入库很常见），而分页是 `LIMIT/OFFSET` —— 排序键不唯一时翻页会重复/漏图。
 * `image.id` 是主键，补上就得到一个全序，分页才是稳定的。
 *
 * ⚠️ 相册配置用的 `ALBUM_IMAGE_SORTING_ORDER` 里对应的两条**缺**这个兜底键，
 * 那是既有隐患（本次不动，见实施计划的"后续批次"）。
 */
export const IMAGE_SORT_ORDERS = {
  /** 上传时间从新到旧 —— iOS 主页「按上传时间」用的就是它 */
  uploaded_desc: 'image.created_at DESC, image.updated_at DESC, image.id DESC',
  uploaded_asc: 'image.created_at ASC, image.updated_at ASC, image.id ASC',
  taken_desc: `${HOME_IMAGE_SORTING_ORDER}, image.id DESC`,
  taken_asc: `${EXIF_CAPTURE_TIME_SQL} ASC, image.created_at ASC, image.updated_at ASC, image.id ASC`,
} as const

export type ImageSort = keyof typeof IMAGE_SORT_ORDERS

export const IMAGE_SORT_VALUES = Object.keys(IMAGE_SORT_ORDERS) as ImageSort[]

/**
 * 解析 `sort` 查询参数。
 *
 * 非法值**回退到 undefined**（= 现状），与 `parsePage` 的"非法回退 1、不报错"同一风格：
 * 客户端把一个参数写错，不该让整个列表打不开。
 */
export function parseImageSort(value: string | null | undefined): ImageSort | undefined {
  if (!value) return undefined
  return Object.prototype.hasOwnProperty.call(IMAGE_SORT_ORDERS, value)
    ? (value as ImageSort)
    : undefined
}
