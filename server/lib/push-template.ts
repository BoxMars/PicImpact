/**
 * 推送文案模板（纯函数，可单测）。
 *
 * 为什么要有：通知正文是「产品文案」，会想改（"「X」刚刚上传" / "X 上新了" / 干脆固定一句话）。
 * 把它做成 `configs.push_body_template` 之后，后台改字就能生效，不用发版、不用改代码。
 *
 * 支持两个占位符（大小写不敏感，花括号内的空格也容忍）：
 *   `{{title}}` → 照片标题（没有标题时退回文件名，再没有就写「一张新照片」）
 *   `{{album}}` → 相册名（相册名就是通知里原来的副标题，去掉副标题后需要的话可以写进正文）
 *
 * 渲染后为空（例如模板只有 `{{album}}` 而相册名缺失）→ 回落到默认文案，绝不发一条空正文的推送。
 */

export const DEFAULT_PUSH_BODY_TEMPLATE = '「{{title}}」刚刚上传'

/** 照片没有标题、也没有文件名时，`{{title}}` 的兜底取值 */
export const FALLBACK_TITLE = '一张新照片'

export interface PushTemplateValues {
  title?: string | null
  album?: string | null
}

/** 模板里能用的占位符，后台界面上直接列出来给用户看 */
export const PUSH_TEMPLATE_PLACEHOLDERS = ['{{title}}', '{{album}}'] as const

function pickTitle(value: string | null | undefined): string {
  const trimmed = (value ?? '').trim()
  return trimmed || FALLBACK_TITLE
}

/**
 * 渲染正文。
 *
 * @param template 模板；为空/空白时用默认模板
 * @param values   `{{title}}` / `{{album}}` 的取值
 */
export function renderPushBody(
  template: string | null | undefined,
  values: PushTemplateValues
): string {
  const source = (template ?? '').trim() || DEFAULT_PUSH_BODY_TEMPLATE

  const title = pickTitle(values.title)
  const album = (values.album ?? '').trim()

  const rendered = source
    // 花括号内允许空格：`{{ title }}` 也认
    .replace(/\{\{\s*title\s*\}\}/gi, title)
    .replace(/\{\{\s*album\s*\}\}/gi, album)
    // 占位符替换成空串后可能留下多余空格，压一下
    .replace(/[ \t]{2,}/g, ' ')
    .trim()

  // 整句都被替空（比如模板只有一个 {{album}} 而相册没名字）→ 退回默认，别发空正文
  return rendered || renderPushBody(DEFAULT_PUSH_BODY_TEMPLATE, values)
}

/** 后台保存前的校验：长度 1–300，允许任意文字（含中文），只挡空与控制字符 */
export function isValidPushTemplate(template: string): boolean {
  const trimmed = template.trim()
  return trimmed.length >= 1 && trimmed.length <= 300 && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(trimmed)
}
