#!/usr/bin/env node
/**
 * 由 messages/zh.json 生成 Swift 侧的回退文案表。
 *
 * 为什么需要回退表：iOS 上 `.xcstrings` 会由 Xcode 编译进 bundle，`String(localized:)` 可用；
 * 但 macOS 的 `swift build`（单元测试所在环境）**不编译** .xcstrings，
 * 于是查表会返回裸 key，测试与本地预览都会显示成 "Exif.basicInfo" 这种东西。
 *
 * 所以：优先走系统本地化，取不到再回退到这张表。表由脚本生成，因此不会与 Web 文案漂移。
 *
 * 用法：node scripts/ios-strings-swift.mjs [--check]
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const OUT = 'ios/PicImpactKit/Sources/PicImpactKit/Generated/IslandStrings+Generated.swift'
const checkMode = process.argv.includes('--check')

function flatten(object, prefix = '', into = {}) {
  for (const [key, value] of Object.entries(object)) {
    const path = prefix ? `${prefix}.${key}` : key
    if (value && typeof value === 'object' && !Array.isArray(value)) flatten(value, path, into)
    else if (typeof value === 'string') into[path] = value
  }
  return into
}

const zh = flatten(JSON.parse(readFileSync('messages/zh.json', 'utf8')))
const keys = Object.keys(zh).sort()

const escape = (v) => v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')

const lines = keys.map((k) => `        "${escape(k)}": "${escape(zh[k])}",`)

const swift = `// 本文件由 scripts/ios-strings-swift.mjs 生成，请勿手改。
// 来源：messages/zh.json（与 Web 端同一份文案）
//
// 用途：当系统本地化取不到时（例如 macOS 的 swift build 不编译 .xcstrings）作为回退，
// 避免界面显示成裸 key。
import Foundation

extension IslandStrings {
    /// 简体中文回退表（${keys.length} 条）
    static let fallback: [String: String] = [
${lines.join('\n')}
    ]
}
`

if (checkMode) {
  if (!existsSync(OUT)) {
    console.error(`  ✗ ${OUT} 不存在，请运行 node scripts/ios-strings-swift.mjs`)
    process.exit(1)
  }
  if (readFileSync(OUT, 'utf8') !== swift) {
    console.error(`  ✗ ${OUT} 与 messages/zh.json 不同步，请重新生成`)
    process.exit(1)
  }
  console.log(`  ✓ 回退文案表与 messages/zh.json 同步（${keys.length} 条）`)
} else {
  mkdirSync(dirname(OUT), { recursive: true })
  writeFileSync(OUT, swift)
  console.log(`已写入 ${OUT}`)
  console.log(`  ${keys.length} 条文案`)
}
