/**
 * 重生缩略图（P0.2 历史数据迁移）。
 *
 * 背景见 `server/lib/thumbnail.ts` 与
 * `docs/superpowers/specs/2026-10-03-performance-design.md` 的 R1 / R1.2：
 * 原实现的 `preview_url` 与**原图像素尺寸完全相同**（只重编码、未缩放），
 * 另有 8 行是空字符串（会回退到全分辨率原图作为网格缩略图）。
 *
 * 用法：
 *   npx tsx scripts/migrate/regenerate-previews.ts                    # dry-run，只报告
 *   npx tsx scripts/migrate/regenerate-previews.ts --limit=2 --apply
 *   npx tsx scripts/migrate/regenerate-previews.ts --apply            # 全量
 *
 * 裁决（见 spec R1.2）：**无条件重生全部行**，不做"看起来合格就跳过"的判断 ——
 * 原缺陷的表现恰恰是"形态合格（webp + 在 preview 目录）但像素尺寸未缩放"，
 * 形态检查识别不出来。39 行规模下重生成本可忽略。
 *
 * 同时用原图**应用 EXIF 方向后**的真实显示尺寸修正 `width`/`height`
 * （原实现 `checkOrientation: false` 导致部分行宽高互换）。
 *
 * 幂等：重复执行只会产生新的缩略图对象并把 `preview_url` 指向它；旧对象成为孤儿，
 * **不删除** —— 留孤儿比误删安全。
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

import { Prisma, PrismaClient } from '@prisma/client'

import type { Config } from '../../types'
import {
  R2_CONFIG_KEYS,
  S3_CONFIG_KEYS,
  ensureManagedPreviewUrl,
  resolveStorageTargets,
} from '../../server/lib/preview-storage'

type CliOptions = { apply: boolean; limit: number; concurrency: number }

type ImageRow = {
  id: string
  url: string | null
  preview_url: string | null
  width: number
  height: number
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

const fmtBytes = (n: number) =>
  n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(2)} MB`

const pct = (a: number, b: number) => (b > 0 ? ((1 - a / b) * 100).toFixed(1) : '0')

/**
 * 用只读 SQL 读配置再映射成 `Config[]`，避免依赖 Next 的 `~` 路径别名与
 * 'use server' 模块（迁移脚本在纯 Node 下跑）。
 */
async function loadConfigs(prisma: PrismaClient): Promise<Config[]> {
  const keys = [...R2_CONFIG_KEYS, ...S3_CONFIG_KEYS]
  // 必须用 Prisma.join 展开成多个占位符；写成 `IN (${keys.join(',')})` 会把整个列表
  // 当成单个字符串参数，匹配不到任何行（首次实现踩过这个坑）。
  const rows = await prisma.$queryRaw<Array<{ config_key: string; config_value: string | null }>>`
    SELECT config_key, config_value FROM configs WHERE config_key IN (${Prisma.join(keys)})
  `
  return rows.map((r) => ({
    id: r.config_key,
    config_key: r.config_key,
    config_value: r.config_value,
    detail: null,
  })) as Config[]
}

async function run() {
  const options = parseArgs(process.argv.slice(2))
  const prisma = new PrismaClient()

  console.log(`\n=== 重生缩略图 ${options.apply ? '【APPLY 会写入】' : '【DRY-RUN 只读】'} ===`)
  console.log(`limit=${options.limit || '全部'} concurrency=${options.concurrency}\n`)

  try {
    const targets = resolveStorageTargets(await loadConfigs(prisma))
    if (!targets.length) {
      throw new Error('没有任何可用的存储后端配置（R2 / S3 都缺），无法写入缩略图')
    }
    console.log(`存储后端: ${targets.map((t) => `${t.kind}(${t.bucket} @ ${t.publicPrefix})`).join(', ')}`)

    const all = await prisma.$queryRaw<ImageRow[]>`
      SELECT id, url, preview_url, width, height FROM images WHERE del = 0 ORDER BY created_at DESC
    `
    const rows = options.limit > 0 ? all.slice(0, options.limit) : all
    console.log(`待处理 ${rows.length} / ${all.length} 行\n`)

    let backupPath = ''
    if (options.apply) {
      const stamp = new Date().toISOString().replace(/[:.]/g, '-')
      backupPath = resolve(process.cwd(), `scripts/migrate/backups/regenerate-previews-${stamp}.json`)
      mkdirSync(dirname(backupPath), { recursive: true })
      writeFileSync(backupPath, JSON.stringify(all, null, 2))
      console.log(`回滚快照已写入：${backupPath}\n`)
    }

    const totals = {
      originalBytes: 0,
      previewBytes: 0,
      updated: 0,
      skipped: 0,
      failed: 0,
      dimsFixed: 0,
    }
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

        try {
          const result = await ensureManagedPreviewUrl(row.url, targets)
          if (!result.ok) {
            console.log(`${tag} 跳过：${result.reason}`)
            totals.skipped++
            continue
          }

          const dimsChanged =
            result.originalWidth > 0 &&
            result.originalHeight > 0 &&
            (row.width !== result.originalWidth || row.height !== result.originalHeight)

          if (options.apply) {
            await prisma.$executeRaw`
              UPDATE images SET
                preview_url = ${result.previewUrl},
                width = ${result.originalWidth || row.width},
                height = ${result.originalHeight || row.height},
                "updated_at" = NOW()
              WHERE id = ${row.id}
            `
          }

          totals.originalBytes += result.originalBytes
          totals.previewBytes += result.previewBytes
          totals.updated++
          if (dimsChanged) totals.dimsFixed++

          console.log(
            `${tag} ${result.width}x${result.height}  ` +
              `原图 ${fmtBytes(result.originalBytes)} → 缩略图 ${fmtBytes(result.previewBytes)} ` +
              `(−${pct(result.previewBytes, result.originalBytes)}%)  ` +
              `${dimsChanged ? `宽高修正 ${row.width}x${row.height}→${result.originalWidth}x${result.originalHeight}  ` : ''}` +
              `${options.apply ? '已更新' : '将更新'}`,
          )
        } catch (e) {
          totals.failed++
          console.error(`${tag} 失败：${e instanceof Error ? e.message : String(e)}`)
        }
      }
    }

    await Promise.all(Array.from({ length: options.concurrency }, (_, i) => worker(i + 1)))

    console.log('\n=== 汇总 ===')
    console.log(`  处理成功: ${totals.updated}`)
    console.log(`  其中宽高被修正: ${totals.dimsFixed}`)
    console.log(`  跳过:     ${totals.skipped}`)
    console.log(`  失败:     ${totals.failed}`)
    if (totals.originalBytes > 0) {
      console.log(`  原图总字节:   ${fmtBytes(totals.originalBytes)}`)
      console.log(`  缩略图总字节: ${fmtBytes(totals.previewBytes)}`)
      console.log(`  压缩比:       ${pct(totals.previewBytes, totals.originalBytes)}%`)
    }
    console.log(options.apply ? `\n回滚快照：${backupPath}` : '\n这是 dry-run，未写入任何内容。加 --apply 执行。')
  } finally {
    await prisma.$disconnect()
  }
}

run().catch((e) => {
  console.error('迁移失败：', e)
  process.exit(1)
})
