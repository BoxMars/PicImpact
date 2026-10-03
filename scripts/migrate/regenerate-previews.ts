/**
 * 重生缩略图（P0.2 历史数据迁移）。
 *
 * 背景见 `server/lib/thumbnail.ts` 顶部注释与
 * `docs/superpowers/specs/2026-10-03-performance-design.md` 的 R1 / R1.2：
 * 现有 `preview_url` 指向的文件与**原图像素尺寸完全相同**（压缩但未缩放），
 * 另外 8 行是空字符串（会回退到全分辨率原图作为网格缩略图）。
 *
 * 用法：
 *   npx tsx scripts/migrate/regenerate-previews.ts                 # dry-run，只报告
 *   npx tsx scripts/migrate/regenerate-previews.ts --limit=2 --apply
 *   npx tsx scripts/migrate/regenerate-previews.ts --apply          # 全量
 *
 * 裁决（见 spec R1.2）：**无条件重生全部行**，不做"看起来合格就跳过"的判断 ——
 * 因为原缺陷的表现恰恰是"形态合格（webp + 在 preview 目录）但像素尺寸未缩放"，
 * 形态检查无法识别，跳过逻辑会漏掉真正有问题的行。39 行规模下重生成本可忽略。
 *
 * 幂等：重复执行只会产生新的缩略图对象并把 `preview_url` 指向它（旧的成为孤儿对象，
 * 不删除 —— 留孤儿比误删安全）。
 */

import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

import { Prisma, PrismaClient } from '@prisma/client'
import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3'
import { createId } from '@paralleldrive/cuid2'

import { buildPreviewKey, generateThumbnail } from '../../server/lib/thumbnail'

type CliOptions = {
  apply: boolean
  limit: number
  concurrency: number
}

type R2Config = {
  accessKeyId: string
  secretAccessKey: string
  accountId: string
  bucket: string
  storageFolder: string
  publicDomain: string
}

type ImageRow = {
  id: string
  url: string | null
  preview_url: string | null
}

function parseArgs(argv: string[]): CliOptions {
  const limitArg = argv.find((a) => a.startsWith('--limit='))
  const concurrencyArg = argv.find((a) => a.startsWith('--concurrency='))
  const limit = limitArg ? Number.parseInt(limitArg.split('=')[1], 10) : 0
  const concurrency = concurrencyArg ? Number.parseInt(concurrencyArg.split('=')[1], 10) : 3
  return {
    apply: argv.includes('--apply'),
    limit: Number.isNaN(limit) ? 0 : Math.max(0, limit),
    concurrency: Number.isNaN(concurrency) ? 3 : Math.max(1, concurrency),
  }
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1048576).toFixed(2)} MB`
}

/** 用只读 SQL 读配置，避免依赖 Next 的 `~` 别名与 'use server' 模块。 */
async function loadR2Config(prisma: PrismaClient): Promise<R2Config> {
  const keys = [
    'r2_accesskey_id',
    'r2_accesskey_secret',
    'r2_account_id',
    'r2_bucket',
    'r2_storage_folder',
    'r2_public_domain',
  ]
  // 注意：必须用 Prisma.join 展开成多个占位符；写成 `IN (${keys.join(',')})` 会把整个
  // 列表当成单个字符串参数，匹配不到任何行（首次实现就踩了这个坑）。
  const rows = await prisma.$queryRaw<Array<{ config_key: string; config_value: string | null }>>`
    SELECT config_key, config_value FROM configs WHERE config_key IN (${Prisma.join(keys)})
  `
  const get = (k: string) => rows.find((r) => r.config_key === k)?.config_value ?? ''
  const cfg: R2Config = {
    accessKeyId: get('r2_accesskey_id'),
    secretAccessKey: get('r2_accesskey_secret'),
    accountId: get('r2_account_id'),
    bucket: get('r2_bucket'),
    storageFolder: get('r2_storage_folder'),
    publicDomain: get('r2_public_domain').replace(/\/+$/, ''),
  }
  const missing = (Object.entries(cfg) as Array<[string, string]>)
    .filter(([, v]) => !v)
    .map(([k]) => k)
  if (missing.length) {
    throw new Error(`R2 配置缺失：${missing.join(', ')}（本脚本当前只支持 R2 后端）`)
  }
  return cfg
}

/** 由公开 URL 反推 object key；不是本资产域的 URL 返回 null（无法安全推导 key）。 */
function urlToKey(url: string, publicDomain: string): string | null {
  const prefix = `${publicDomain}/`
  if (!url.startsWith(prefix)) return null
  return url.slice(prefix.length)
}

async function run() {
  const options = parseArgs(process.argv.slice(2))
  const prisma = new PrismaClient()

  console.log(`\n=== 重生缩略图 ${options.apply ? '【APPLY 会写入】' : '【DRY-RUN 只读】'} ===`)
  console.log(`limit=${options.limit || '全部'} concurrency=${options.concurrency}\n`)

  try {
    const cfg = await loadR2Config(prisma)
    console.log(`R2: bucket=${cfg.bucket} folder=${cfg.storageFolder} domain=${cfg.publicDomain}`)

    const all = await prisma.$queryRaw<ImageRow[]>`
      SELECT id, url, preview_url FROM images WHERE del = 0 ORDER BY created_at DESC
    `
    const rows = options.limit > 0 ? all.slice(0, options.limit) : all
    console.log(`待处理 ${rows.length} / ${all.length} 行\n`)

    // 快照：apply 前把当前值落盘，作为回滚依据
    let backupPath = ''
    if (options.apply) {
      const stamp = new Date().toISOString().replace(/[:.]/g, '-')
      backupPath = resolve(process.cwd(), `scripts/migrate/backups/regenerate-previews-${stamp}.json`)
      mkdirSync(dirname(backupPath), { recursive: true })
      writeFileSync(backupPath, JSON.stringify(all, null, 2))
      console.log(`回滚快照已写入：${backupPath}\n`)
    }

    const s3 = new S3Client({
      region: 'auto',
      endpoint: `https://${cfg.accountId}.r2.cloudflarestorage.com`,
      credentials: { accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey },
    })

    const totals = { originalBytes: 0, thumbBytes: 0, updated: 0, skipped: 0, failed: 0 }
    let cursor = 0

    async function worker(workerId: number) {
      while (true) {
        const index = cursor++
        if (index >= rows.length) return
        const row = rows[index]
        const tag = `[w${workerId}] ${row.id}`

        if (!row.url) {
          console.log(`${tag} 跳过：url 为空`)
          totals.skipped++
          continue
        }

        const originalKey = urlToKey(row.url, cfg.publicDomain)
        if (!originalKey) {
          console.log(`${tag} 跳过：url 不在资产域内（${row.url.slice(0, 60)}）`)
          totals.skipped++
          continue
        }

        try {
          const res = await fetch(row.url)
          if (!res.ok) throw new Error(`下载失败 HTTP ${res.status}`)
          const original = Buffer.from(await res.arrayBuffer())

          const thumb = await generateThumbnail(original)
          const previewKey = buildPreviewKey(originalKey, createId())
          const previewUrl = `${cfg.publicDomain}/${previewKey}`

          if (options.apply) {
            await s3.send(
              new PutObjectCommand({
                Bucket: cfg.bucket,
                Key: previewKey,
                Body: thumb.buffer,
                ContentType: thumb.contentType,
                // 文件名是内容哈希（cuid），对象不可变 → 长 TTL 让边缘与浏览器长期缓存
                CacheControl: 'public, max-age=31536000, immutable',
              }),
            )
            await prisma.$executeRaw`
              UPDATE images SET preview_url = ${previewUrl}, "updated_at" = NOW() WHERE id = ${row.id}
            `
          }

          totals.originalBytes += original.length
          totals.thumbBytes += thumb.buffer.length
          totals.updated++
          const ratio = ((1 - thumb.buffer.length / original.length) * 100).toFixed(1)
          console.log(
            `${tag} ${thumb.width}x${thumb.height}  ` +
              `原图 ${fmtBytes(original.length)} → 缩略图 ${fmtBytes(thumb.buffer.length)} (−${ratio}%)  ` +
              `${options.apply ? '已更新' : '将更新 → ' + previewKey}`,
          )
        } catch (e) {
          totals.failed++
          console.error(`${tag} 失败：${e instanceof Error ? e.message : String(e)}`)
        }
      }
    }

    await Promise.all(
      Array.from({ length: options.concurrency }, (_, i) => worker(i + 1)),
    )

    console.log(`\n=== 汇总 ===`)
    console.log(`  处理成功: ${totals.updated}`)
    console.log(`  跳过:     ${totals.skipped}`)
    console.log(`  失败:     ${totals.failed}`)
    if (totals.originalBytes > 0) {
      console.log(`  原图总字节:   ${fmtBytes(totals.originalBytes)}`)
      console.log(`  缩略图总字节: ${fmtBytes(totals.thumbBytes)}`)
      console.log(
        `  压缩比:       ${(1 - totals.thumbBytes / totals.originalBytes > 0
          ? ((1 - totals.thumbBytes / totals.originalBytes) * 100).toFixed(1)
          : '0')}%`,
      )
    }
    if (!options.apply) {
      console.log(`\n这是 dry-run，未写入任何内容。加 --apply 执行。`)
    } else if (backupPath) {
      console.log(`\n回滚快照：${backupPath}`)
    }
  } finally {
    await prisma.$disconnect()
  }
}

run().catch((e) => {
  console.error('迁移失败：', e)
  process.exit(1)
})
