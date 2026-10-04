/**
 * 公开 API 契约校验。
 *
 * 目的：**确保后续 Web 端改动不会悄悄打断已发布的旧版 App。**
 *
 * 为什么需要它：v1 的 DTO 形状是靠 hono/public-api/v1/serialize.ts 手写映射维持的。
 * 有人在里面删掉一个字段、把 `previewUrl` 改名、或让 `width` 从 number 变成 string，
 * 类型检查**不会报错**（DTO 是普通对象），App 却会在解码时整页失败。
 * 这个脚本把"形状"落成 fixture 并逐键比对，让破坏性变更在提交前就暴露。
 *
 * 规则：**只能加字段，不能删/改名/改类型。** 加字段属于兼容变更，脚本会提示但不失败。
 *
 * 用法：pnpm api:verify-contract
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  toAlbumDTOv1,
  toImageDTOv1,
  toSiteConfigDTOv1,
} from '../../hono/public-api/v1/serialize'

type ExpectedTypes = Record<string, string>

interface ShapeSpec {
  required: string[]
  types: ExpectedTypes
  /** 嵌套对象的形状（用于 config.site / config.features —— 那里的键被改名会让 App 静默失效） */
  nested?: Record<string, ShapeSpec>
}

interface Contract {
  v1: Record<string, ShapeSpec>
}

const contractPath = join(process.cwd(), 'docs/superpowers/api/fixtures/v1-contract.json')
const contract = JSON.parse(readFileSync(contractPath, 'utf8')) as Contract

/** 取运行期类型标签，与 fixture 里的写法对齐（支持 "object|null" 这类联合） */
function typeOf(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  return typeof value
}

function matches(actual: string, expected: string): boolean {
  return expected.split('|').includes(actual)
}

// ---- 构造样本 ----------------------------------------------------------------
// 刻意填满所有字段（含 null / 空数组这类边界），以便同时验证类型与归一化行为。
const sampleImage = {
  id: 'sample_id_0001',
  image_name: 'DSC01234.ARW',
  url: 'https://felina-asset.boxz.dev/images/daily/original.jpg',
  preview_url: 'https://felina-asset.boxz.dev/images/daily/preview/abc.webp',
  video_url: '',
  blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
  exif: { make: 'SONY', model: 'ILCE-7M4', data_time: '2026:10:04 12:00:00' },
  labels: ['日常', '街拍'],
  width: 6000,
  height: 4000,
  lon: '139.7671',
  lat: '35.6812',
  title: '标题',
  detail: '描述',
  type: 1,
  show: 0,
  show_on_mainpage: 0,
  sort: 0,
  created_at: new Date('2026-10-04T04:00:00.000Z'),
  album_license: 'CC BY-NC 4.0',
}

const sampleAlbum = {
  id: 'album_id_0001',
  name: '日常',
  album_value: '/daily',
  detail: null,
  theme: '0',
  show: 0,
  sort: 1,
  license: null,
  image_sorting: 1,
  random_show: 1,
}

// ---- 校验 --------------------------------------------------------------------
const failures: string[] = []
const notices: string[] = []

function check(label: string, actual: Record<string, unknown>, expected: ShapeSpec) {
  for (const key of expected.required) {
    if (!(key in actual)) {
      failures.push(`${label}: 缺少必需字段 \`${key}\` —— 这会打断已发布的 App（只能加字段，不能删/改名）`)
      continue
    }
    const actualType = typeOf(actual[key])
    const wantTypes = expected.types[key]
    if (wantTypes && !matches(actualType, wantTypes)) {
      failures.push(`${label}: 字段 \`${key}\` 类型变了，期望 \`${wantTypes}\`，实际 \`${actualType}\``)
    }
  }
  for (const key of Object.keys(actual)) {
    if (!expected.required.includes(key)) {
      notices.push(`${label}: 新增字段 \`${key}\`（兼容变更，记得同步更新 fixture 与 docs）`)
    }
  }
  // 递归校验嵌套对象
  for (const [key, sub] of Object.entries(expected.nested ?? {})) {
    const child = actual[key]
    if (child && typeof child === 'object') {
      check(`${label}.${key}`, child as Record<string, unknown>, sub)
    }
  }
}

// @ts-expect-error 样本刻意只填 DTO 用得到的字段，不是完整 ImageType
const imageDTO = toImageDTOv1(sampleImage)
// @ts-expect-error 同上一处：样本只填 DTO 用得到的字段
const albumDTO = toAlbumDTOv1(sampleAlbum)

check('v1.image', imageDTO as unknown as Record<string, unknown>, contract.v1.image)
check('v1.album', albumDTO as unknown as Record<string, unknown>, contract.v1.album)

// config：布尔语义必须与 Web 端一致（'true' 字符串，不是 '1'）
const configRows = [
  { config_key: 'custom_title', config_value: '大福映画 Felina Gallery' },
  { config_key: 'custom_index_style', config_value: '1' },
  { config_key: 'custom_index_download_enable', config_value: 'true' },
  { config_key: 'custom_index_origin_enable', config_value: 'true' },
]
const configDTO = toSiteConfigDTOv1(configRows, 'v1', 24)
check('v1.config', configDTO as unknown as Record<string, unknown>, contract.v1.config)

if (configDTO.features.download !== true || configDTO.features.origin !== true) {
  failures.push(
    'v1.config: 布尔判定错误 —— 库里存的是字符串 "true"，不是 "1"。写成 === \'1\' 会让已开启的下载入口被隐藏'
  )
}
if (configDTO.site.indexStyle !== '1') {
  failures.push(
    'v1.config: site.indexStyle 未正确映射（检查 PUBLIC_CONFIG_KEYS 是否漏了 custom_index_style）'
  )
}

// 额外断言：labels 必须归一化为数组（库里是 json，可能是 null 或脏数据）
if (!Array.isArray(imageDTO.labels)) {
  failures.push('v1.image: `labels` 未归一化为数组')
}
const dirtyLabels = toImageDTOv1({ ...sampleImage, labels: null } as never)
if (!Array.isArray(dirtyLabels.labels) || dirtyLabels.labels.length !== 0) {
  failures.push('v1.image: `labels` 为 null 时未归一化为空数组')
}
// 时间必须归一化为 ISO 字符串
if (typeof imageDTO.createdAt !== 'string' || !imageDTO.createdAt.endsWith('Z')) {
  failures.push('v1.image: `createdAt` 未归一化为 ISO 8601（UTC）字符串')
}

// ---- 输出 --------------------------------------------------------------------
for (const notice of notices) console.log(`  · ${notice}`)

if (failures.length > 0) {
  console.error('\n公开 API v1 契约校验失败：\n')
  for (const f of failures) console.error(`  ✗ ${f}`)
  console.error(
    '\n如果是刻意的破坏性变更：不要改 v1，改为新增 /v2（见 docs/superpowers/api/public-api-v1.md）。\n'
  )
  process.exit(1)
}

console.log('\n✓ 公开 API v1 契约校验通过（字段与类型均未破坏）')
