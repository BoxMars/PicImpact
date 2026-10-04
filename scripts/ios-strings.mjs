#!/usr/bin/env node
/**
 * 由 Web 端的 `messages/*.json` 生成 iOS 的 String Catalog（Localizable.xcstrings），
 * 并校验四语言 key 是否齐全。
 *
 * 为什么要有这个脚本，而不是手抄：
 * Web 端有 365 个 key × 4 种语言。手抄必然漂移，而且漂移是**静默的** ——
 * 界面上只会出现一个 key 字符串，不会报错。这个脚本把"两端文案一致"变成可机器判定的。
 *
 * 用法：
 *   node scripts/ios-strings.mjs           # 生成
 *   node scripts/ios-strings.mjs --check   # 校验是否与 JSON 同步（CI 用），不同步则 exit 1
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname } from 'node:path'

const LOCALES = ['zh', 'en', 'ja', 'zh-TW']
const OUT = 'ios/PicImpact/Resources/Localizable.xcstrings'
const checkMode = process.argv.includes('--check')

/** 展平成点号路径 → 字符串。只取叶子字符串，忽略嵌套对象本身。 */
function flatten(object, prefix = '', into = {}) {
  for (const [key, value] of Object.entries(object)) {
    const path = prefix ? `${prefix}.${key}` : key
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      flatten(value, path, into)
    } else if (typeof value === 'string') {
      into[path] = value
    }
  }
  return into
}

const catalogs = {}
for (const locale of LOCALES) {
  const path = `messages/${locale}.json`
  catalogs[locale] = flatten(JSON.parse(readFileSync(path, 'utf8')))
}

// ---------------------------------------------------------------------------
// 校验：key 集合必须一致（否则某语言界面会出现原始 key）
// ---------------------------------------------------------------------------
const source = catalogs.zh
const sourceKeys = new Set(Object.keys(source))
let problems = 0

for (const locale of LOCALES) {
  if (locale === 'zh') continue
  const keys = new Set(Object.keys(catalogs[locale]))
  const missing = [...sourceKeys].filter((k) => !keys.has(k))
  const extra = [...keys].filter((k) => !sourceKeys.has(k))
  if (missing.length) {
    problems += missing.length
    console.error(`  ✗ ${locale} 缺少 ${missing.length} 个 key，例如：${missing.slice(0, 5).join(', ')}`)
  }
  if (extra.length) {
    // 多余的 key 不算错误（可能是待清理的旧文案），但提示出来
    console.warn(`  · ${locale} 多出 ${extra.length} 个 key（非致命）：${extra.slice(0, 5).join(', ')}`)
  }
}

// ---------------------------------------------------------------------------
// 生成 String Catalog
// ---------------------------------------------------------------------------
const strings = {}
for (const key of [...sourceKeys].sort()) {
  const localizations = {}
  for (const locale of LOCALES) {
    const value = catalogs[locale][key]
    if (value === undefined) continue
    localizations[locale] = {
      stringUnit: { state: 'translated', value },
    }
  }
  strings[key] = { extractionState: 'manual', localizations }
}

const catalog = {
  sourceLanguage: 'zh',
  strings,
  version: '1.0',
}

const serialized = JSON.stringify(catalog, null, 2) + '\n'

if (checkMode) {
  if (!existsSync(OUT)) {
    console.error(`  ✗ ${OUT} 不存在，请运行 node scripts/ios-strings.mjs 生成`)
    process.exit(1)
  }
  const current = readFileSync(OUT, 'utf8')
  if (current !== serialized) {
    console.error(
      `  ✗ ${OUT} 与 messages/*.json 不同步。\n` +
        `     Web 端改过文案但没有重新生成 → iOS 界面会显示旧文案或原始 key。\n` +
        `     运行 node scripts/ios-strings.mjs 重新生成。`
    )
    process.exit(1)
  }
  console.log(`  ✓ ${OUT} 与 messages/*.json 同步（${Object.keys(strings).length} 个 key × ${LOCALES.length} 语言）`)
} else {
  mkdirSync(dirname(OUT), { recursive: true })
  writeFileSync(OUT, serialized)
  console.log(`已写入 ${OUT}`)
  console.log(`  key 数：${Object.keys(strings).length}`)
  console.log(`  语言：${LOCALES.join(', ')}`)
}

process.exit(problems > 0 ? 1 : 0)
