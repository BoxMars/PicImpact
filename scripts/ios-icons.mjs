#!/usr/bin/env node
/**
 * 把 animal-island-ui 的 ACNH 图标 SVG 提取进 Swift 包的资源目录。
 *
 * 为什么要这么做，而不是用 SF Symbols 凑：
 * 这些图标是**彩色的 ACNH 自绘素材**（例如 icon-camera 含 #FF66AD 粉、#9364DE 紫、
 * #4C3C33 棕），是这套视觉识别的一部分。SF Symbols 全是单色线性图标，形状与配色都对不上，
 * 直接用会让卡片"一眼就不是 ACNH"。
 *
 * 为什么脚本化：图标会随上游库升级而变化。手抄一次之后没人会记得更新；
 * 脚本可以随时重跑（`node scripts/ios-icons.mjs`），并且能校验 8 个图标一个不少。
 *
 * 用法：node scripts/ios-icons.mjs [--check]
 *   --check  只校验资源是否与上游一致（CI 用）
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'

const UPSTREAM_FILES = 'node_modules/animal-island-ui/dist/files'
// 刻意**不放进 asset catalog**：macOS 的 swift build 不跑 actool，资源不会编译成
// Assets.car，Image(name:) 会静默取不到东西（已实测）。改为普通资源文件 + 自己渲染 SVG。
const ICONS_DIR = 'ios/PicImpactKit/Sources/PicImpactKit/Resources/Icons'

/**
 * Web 卡片实际用到的图标（见 components/gallery/simple/gallery-image.tsx）。
 * 只取需要的 —— 不把整个图标库搬进 App。
 */
/**
 * 装饰图形（同样属于展示效果，需与 Web 一致）。
 * wave-yellow 是 simple 画廊头部下方的波浪分隔线（`<Divider type="wave-yellow">`），
 * 它自带 fill="#f1e26f"，由本包的 SVG 渲染器直接画出来。
 */
const DECORATIONS = {
  'wave-yellow': '头部下方的波浪分隔线',
}

const ICONS = {
  'icon-camera': 'EXIF · 相机（make + model）',
  'icon-variant': 'EXIF · 光圈',
  'icon-miles': 'EXIF · 曝光时间',
  'icon-map': 'EXIF · 焦距',
  'icon-critterpedia': 'EXIF · 感光度 ISO',
  'icon-diy': '操作 · 复制图片链接',
  'icon-helicopter': '操作 · 复制分享直链',
  'icon-shopping': '操作 · 下载原图',
  'icon-design': '详情页 · 镜头（lens_model）',
  // 注意：详情页的"分享直链"用的是 icon-chat，卡片里的同名操作用的是 icon-helicopter —— 两处不同
  'icon-chat': '详情页 · 分享直链',
}

const checkMode = process.argv.includes('--check')

/** 上游文件名带内容哈希（icon-camera.51fd7127.svg），按前缀匹配 */
function findUpstream(name) {
  const entries = readdirSync(UPSTREAM_FILES)
  const match = entries.find((entry) => entry.startsWith(`${name}.`) && entry.endsWith('.svg'))
  if (!match) throw new Error(`上游找不到图标 ${name}.svg`)
  return join(UPSTREAM_FILES, match)
}

const results = []
let mismatches = 0

for (const [name, purpose] of Object.entries({ ...ICONS, ...DECORATIONS })) {
  const source = findUpstream(name)
  const svg = readFileSync(source, 'utf8')
  const svgPath = join(ICONS_DIR, `${name}.svg`)

  if (checkMode) {
    if (!existsSync(svgPath)) {
      console.error(`  ✗ 缺少 ${svgPath}`)
      mismatches++
      continue
    }
    if (readFileSync(svgPath, 'utf8') !== svg) {
      console.error(`  ✗ ${name} 与上游不一致（上游升级过？重跑 node scripts/ios-icons.mjs）`)
      mismatches++
      continue
    }
    results.push(`  ✓ ${name.padEnd(20)} ${purpose}`)
    continue
  }

  mkdirSync(ICONS_DIR, { recursive: true })
  writeFileSync(svgPath, svg)
  results.push(`  ${name.padEnd(20)} ${purpose}`)
}

if (checkMode) {
  console.log(results.join('\n'))
  if (mismatches > 0) {
    console.error(`\n  ${mismatches} 个图标与上游不一致`)
    process.exit(1)
  }
  const total = Object.keys(ICONS).length + Object.keys(DECORATIONS).length
  console.log(`\n  ✓ ${total} 个素材与上游一致`)
} else {
  console.log(`已写入 ${ICONS_DIR}`)
  console.log(results.join('\n'))
  const total = Object.keys(ICONS).length + Object.keys(DECORATIONS).length
  console.log(`\n  ${Object.keys(ICONS).length} 个图标 + ${Object.keys(DECORATIONS).length} 个装饰图形`)
  console.log('  均为彩色原素材，不可当 template 染色')
}
