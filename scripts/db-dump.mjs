#!/usr/bin/env node
/**
 * 把 DATABASE_URL 指向的库导出为 db-backups/rows-<时间>.json。
 *
 * 与 scripts/db-restore.mjs 配对使用。两个要点：
 *   1. **行级、用真实列名**导出（`SELECT *`），不要用 Prisma 模型的字段名 ——
 *      模型名与表名、字段名与列名都可能不同（本项目里 ImagesAlbumsRelation 对应表
 *      images_albums_relation），用模型导出会漏表。
 *   2. 导出目录 db-backups/ 含存储密钥等敏感配置，已在 .gitignore 中，切勿外传。
 *
 * 用法：node scripts/db-dump.mjs
 */
import { PrismaClient } from '@prisma/client'
import { writeFileSync, mkdirSync } from 'node:fs'

const db = new PrismaClient()
const tables = ['images', 'albums', 'images_albums_relation', 'configs', 'user', 'session', 'account', 'verification', 'passkey', 'two_factor']

mkdirSync('db-backups', { recursive: true })
const out = { exportedAt: new Date().toISOString(), shape: 'raw-db-rows', tables: {} }
let total = 0
for (const t of tables) {
  try {
    const rows = await db.$queryRawUnsafe(`SELECT * FROM "public"."${t}"`)
    // BigInt 无法直接 JSON 序列化
    out.tables[t] = JSON.parse(JSON.stringify(rows, (_, v) => (typeof v === 'bigint' ? Number(v) : v)))
    total += out.tables[t].length
    console.log(`  ${t.padEnd(26)} ${out.tables[t].length} 行`)
  } catch (e) {
    console.log(`  ${t.padEnd(26)} 跳过（${String(e.message || e).slice(0, 50)}）`)
  }
}
const file = `db-backups/rows-${new Date().toISOString().slice(0, 19).replace(/[:]/g, '-')}.json`
writeFileSync(file, JSON.stringify(out, null, 2))
console.log(`\n  已写出 ${file}（共 ${total} 行）`)
console.log('  ⚠ 该文件含敏感配置，目录已在 .gitignore 中')
await db.$disconnect()
