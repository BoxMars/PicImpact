#!/usr/bin/env node
/**
 * 把 db-backups/rows-*.json 还原进 DATABASE_URL 指向的库。
 *
 * 用途：迁移/恢复数据库。数据源用 scripts/db-dump.mjs 生成（**行级、用真实列名**，
 * 不要用 Prisma 模型导出的字段名 —— 模型名与表名、字段名与列名都可能不同，
 * 本次就因此漏掉过 images_albums_relation 的 66 行）。
 *
 * 两个必须踩过的坑（已在本脚本里处理，别退回去）：
 *   1. json / jsonb 列：参数按 text 传会报 42804（column is of type json but expression is of type text）
 *      → 占位符必须显式转换 `$n::json`。
 *   2. 时间列：dump 存成 JSON 后 Date 变成 ISO 字符串，而字符串不会隐式转成 timestamp
 *      → 同样要 `$n::timestamp`。
 *   做法不是逐列硬编码，而是**从目标库读 information_schema 的真实类型**，给每个占位符都加转换；
 *   数组与自定义类型（enum）另行处理。
 *
 * 用法：node scripts/db-restore.mjs [dump文件路径]
 */
import { PrismaClient } from '@prisma/client'
import { readdirSync, readFileSync } from 'node:fs'

const db = new PrismaClient()
const dir = 'db-backups'
const name = process.argv[2] || readdirSync(dir).filter(f => f.startsWith('rows-')).sort().pop()
const file = name.includes('/') ? name : `${dir}/${name}`   // 修正：默认要带目录
if (!file) { console.error('找不到 db-backups/rows-*.json'); process.exit(1) }
const dump = JSON.parse(readFileSync(file, 'utf8'))
console.log(`  数据源: ${file}`)

const meta = await db.$queryRawUnsafe(
  `SELECT table_name, column_name, data_type, udt_name FROM information_schema.columns WHERE table_schema='public'`)
const info = {}
for (const r of meta) info[`${r.table_name}.${r.column_name}`] = r

function sqlType(t, c) {
  const m = info[`${t}.${c}`]
  if (!m) return null
  if (m.data_type === 'ARRAY') return m.udt_name.replace(/^_/, '') + '[]'
  if (m.data_type === 'USER-DEFINED') return `"${m.udt_name}"`
  return m.udt_name
}
const toParam = v => (v === null || v === undefined) ? null : (typeof v === 'object' ? JSON.stringify(v) : v)

// 依赖顺序：被引用的表在前
const order = ['images', 'albums', 'images_albums_relation', 'configs', 'user', 'session', 'account', 'verification', 'passkey', 'two_factor']
let failed = false
for (const t of order) {
  const rows = dump.tables?.[t] || []
  if (!rows.length) { console.log(`  ${t.padEnd(26)} 0 行（跳过）`); continue }
  const cols = Object.keys(rows[0])
  const colList = cols.map(c => `"${c}"`).join(', ')
  const ph = cols.map((c, i) => { const st = sqlType(t, c); return st ? `$${i + 1}::${st}` : `$${i + 1}` }).join(', ')
  let ok = 0
  for (const r of rows) {
    try {
      await db.$executeRawUnsafe(`INSERT INTO "public"."${t}" (${colList}) VALUES (${ph})`, ...cols.map(c => toParam(r[c])))
      ok++
    } catch (e) {
      console.error(`  ✗ ${t} 第 ${ok + 1} 行失败：${String(e.message || e).slice(0, 300)}`)
      failed = true; break
    }
  }
  if (failed) break
  console.log(`  ${t.padEnd(26)} ${ok}/${rows.length} 行`)
}
if (!failed) console.log('\n  完成。建议随后逐表核对行数（见 scripts/db-restore.mjs 的说明）。')
await db.$disconnect()
