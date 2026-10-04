#!/usr/bin/env node
/**
 * 生成影调/直方图算法的**跨语言基准**。
 *
 * 目的：Swift 侧的 `ImageAnalysis` 是从 Web 端 `tone-analysis.tsx` 与
 * `histogram-chart.tsx` 移植过来的。移植最容易出的问题不是"跑不起来"，
 * 而是**阈值/公式抄错了一点点** —— 那样同一张图在两端会得出不同的影调结论，
 * 而且很难被发现。
 *
 * 所以这里把 Web 的算法原样抄一份（含 Math.round 的取整时机、256→128 的合并方式），
 * 对若干可确定性重建的图案算出结果，写成 fixture；
 * Swift 测试再用同样的图案算一遍并逐值比对。
 *
 * 用法：node scripts/ios-analysis-fixture.mjs
 */
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

// ---------------------------------------------------------------------------
// 与 Web 端一致的算法（逐条抄自 components/album/*.tsx）
// ---------------------------------------------------------------------------

function jsLuminance(r, g, b) {
  return Math.round(0.2126 * r + 0.7152 * g + 0.0722 * b)
}

function analyzeTone(pixels) {
  const totalPixels = pixels.length / 4
  if (totalPixels === 0) {
    return { toneType: 'normal', brightness: 50, contrast: 50, shadowRatio: 0.33, highlightRatio: 0.33 }
  }
  const luminanceValues = []
  for (let i = 0; i < pixels.length; i += 4) {
    luminanceValues.push(jsLuminance(pixels[i], pixels[i + 1], pixels[i + 2]))
  }
  const sum = luminanceValues.reduce((acc, val) => acc + val, 0)
  const avgLuminance = sum / totalPixels
  const brightness = Math.round((avgLuminance / 255) * 100)

  const variance =
    luminanceValues.reduce((acc, val) => acc + Math.pow(val - avgLuminance, 2), 0) / totalPixels
  const stdDev = Math.sqrt(variance)
  const contrast = Math.min(100, Math.round((stdDev / 128) * 100))

  let shadowCount = 0
  let highlightCount = 0
  const shadowThreshold = 64
  const highlightThreshold = 192
  for (const lum of luminanceValues) {
    if (lum < shadowThreshold) shadowCount++
    else if (lum > highlightThreshold) highlightCount++
  }
  const shadowRatio = shadowCount / totalPixels
  const highlightRatio = highlightCount / totalPixels

  let toneType
  if (contrast > 60) toneType = 'high-contrast'
  else if (brightness < 35 && shadowRatio > 0.4) toneType = 'low-key'
  else if (brightness > 65 && highlightRatio > 0.4) toneType = 'high-key'
  else toneType = 'normal'

  return { toneType, brightness, contrast, shadowRatio, highlightRatio }
}

function calculateHistogram(pixels) {
  const histogram = {
    red: new Array(256).fill(0),
    green: new Array(256).fill(0),
    blue: new Array(256).fill(0),
    luminance: new Array(256).fill(0),
  }
  for (let i = 0; i < pixels.length; i += 4) {
    const r = pixels[i]
    const g = pixels[i + 1]
    const b = pixels[i + 2]
    histogram.red[r]++
    histogram.green[g]++
    histogram.blue[b]++
    histogram.luminance[jsLuminance(r, g, b)]++
  }
  const compress = (channel) => {
    const compressed = new Array(128).fill(0)
    for (let i = 0; i < 256; i++) compressed[Math.floor(i / 2)] += channel[i]
    return compressed
  }
  return {
    red: compress(histogram.red),
    green: compress(histogram.green),
    blue: compress(histogram.blue),
    luminance: compress(histogram.luminance),
  }
}

// ---------------------------------------------------------------------------
// 可确定性重建的图案（Swift 侧用同一套规则重放，所以不能依赖随机数生成器的实现差异）
// ---------------------------------------------------------------------------

const patterns = {
  'solid-mid-gray': (width, height) => {
    const bytes = []
    for (let i = 0; i < width * height; i++) bytes.push(128, 128, 128, 255)
    return bytes
  },
  'solid-black': (width, height) => {
    const bytes = []
    for (let i = 0; i < width * height; i++) bytes.push(0, 0, 0, 255)
    return bytes
  },
  'solid-white': (width, height) => {
    const bytes = []
    for (let i = 0; i < width * height; i++) bytes.push(255, 255, 255, 255)
    return bytes
  },
  'solid-red': (width, height) => {
    const bytes = []
    for (let i = 0; i < width * height; i++) bytes.push(255, 0, 0, 255)
    return bytes
  },
  checkerboard: (width, height) => {
    const bytes = []
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const value = (x + y) % 2 === 0 ? 0 : 255
        bytes.push(value, value, value, 255)
      }
    }
    return bytes
  },
  /** 横向亮度渐变 0→255，用于验证分箱分布 */
  'gradient-ramp': (width, height) => {
    const bytes = []
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const value = Math.round((x / (width - 1)) * 255)
        bytes.push(value, value, value, 255)
      }
    }
    return bytes
  },
  /** 确定性 LCG 噪声。Swift 侧用同样的整数运算重放（UInt32 溢出即是模 2^32） */
  'lcg-noise': (width, height) => {
    let seed = 12345
    const bytes = []
    const next = () => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0
      return seed
    }
    for (let i = 0; i < width * height; i++) {
      bytes.push(next() & 0xff, next() & 0xff, next() & 0xff, 255)
    }
    return bytes
  },
}

const CASES = Object.keys(patterns).map((name) => ({ name, width: 24, height: 16 }))

const golden = {
  _comment:
    '由 scripts/ios-analysis-fixture.mjs 生成。算法抄自 Web 端 tone-analysis.tsx / histogram-chart.tsx。Swift 侧的 ImageAnalysis 必须逐值一致。',
  cases: {},
}

for (const { name, width, height } of CASES) {
  const pixels = patterns[name](width, height)
  golden.cases[name] = {
    width,
    height,
    tone: analyzeTone(pixels),
    histogram: calculateHistogram(pixels),
  }
}

const out = 'ios/PicImpactKit/Tests/PicImpactKitTests/Fixtures/analysis-golden.json'
mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, JSON.stringify(golden, null, 2) + '\n')

console.log(`已写入 ${out}`)
for (const [name, value] of Object.entries(golden.cases)) {
  const t = value.tone
  console.log(
    `  ${name.padEnd(16)} ${t.toneType.padEnd(14)} brightness=${String(t.brightness).padStart(3)} contrast=${String(t.contrast).padStart(3)} shadow=${t.shadowRatio.toFixed(4)} highlight=${t.highlightRatio.toFixed(4)}`
  )
}
