/**
 * 剥离 animal-island-ui 内联的「未分片」@font-face。
 *
 * 背景（实测 2026-10-03）：该库的 `dist/index.css` 内联了 9 条 @font-face，其中
 * `noto-sans-sc-chinese-simplified` 三个字重各约 1.1MB（400/500/700 = 1115.8/1132.0/1144.8 KB），
 * 且全部没有 unicode-range —— 中文页面必然整包下载约 3.39MB。这是首屏第二大成本。
 *
 * 同一个字体已由 `@fontsource/noto-sans-sc` 提供每字重 101 个 unicode-range 分片的版本
 * （见 `style/globals.css` 的 @import）。这里只删除库自带的未分片声明，让分片版本生效，
 * 字形与字重完全不变（零视觉变化）。
 *
 * ⚠️ 匹配必须精确，否则会把 fontsource 的分片一起删掉，导致中文静默回退到系统字体。
 * 两边的文件名只差一个 hash 段：
 *   animal-island-ui: files/noto-sans-sc-chinese-simplified-400-normal.e25467c8.woff2   ← 有 8 位 hash
 *   fontsource:       files/nunito-latin-500-normal.woff2                              ← 无 hash
 * 因此正则必须要求「.8位hex.woff2」这个形态。
 */
const UNSLICED_FONT_SRC = /files\/(?:noto-sans-sc|nunito)-[a-z0-9-]+\.[0-9a-f]{8}\.woff2/
const EXPECTED_REMOVALS = 9
const MIN_SLICED_RULES = 100

const stripBundledFontFaces = () => ({
  postcssPlugin: 'strip-bundled-font-faces',
  OnceExit(root) {
    // 只处理全局样式表。Next 会用这份 PostCSS 配置处理每个 CSS module
    // （例如 animal-island-ui 的 button.module.css），那些文件里本来就没有字体规则，
    // 在里面跑剥离与断言只会误报。
    const file = root.source?.input?.file ?? ''
    if (!file.includes('style/globals.css') && !file.includes('style\\globals.css')) {
      return
    }

    let removed = 0
    root.walkAtRules('font-face', (rule) => {
      if (UNSLICED_FONT_SRC.test(rule.toString())) {
        rule.remove()
        removed += 1
      }
    })

    // 防御：分片声明必须仍然存在。若剥离过度，中文会静默回退到系统字体 ——
    // 与其静默降级，不如让构建直接失败。
    let slicedRules = 0
    root.walkDecls('unicode-range', () => {
      slicedRules += 1
    })

    if (slicedRules < MIN_SLICED_RULES) {
      throw root.error(
        `strip-bundled-font-faces: 剥离了 ${removed} 条未分片 @font-face，但产出中只剩 ` +
          `${slicedRules} 条 unicode-range（期望 >= ${MIN_SLICED_RULES}）。` +
          '分片字体疑似被误删，中文将回退到系统字体。请检查 UNSLICED_FONT_SRC 是否过宽。',
      )
    }

    if (removed !== EXPECTED_REMOVALS) {
      console.warn(
        `[strip-bundled-font-faces] 剥离了 ${removed} 条未分片 @font-face，期望 ${EXPECTED_REMOVALS} 条。` +
          'animal-island-ui 可能已升级并改了字体文件名，请复核正则。',
      )
    }
  },
})
stripBundledFontFaces.postcss = true

const config = {
  plugins: ['@tailwindcss/postcss', stripBundledFontFaces()],
}

export default config
