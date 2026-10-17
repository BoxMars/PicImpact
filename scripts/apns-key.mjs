#!/usr/bin/env node
/**
 * 把 APNs 的 `.p8` 私钥转成可以塞进环境变量的**单行**形式（换行写成字面量 `\n`）。
 *
 * ## 为什么需要它
 * `.p8` 是多行 PEM，而 Vercel / 大多数环境变量输入框是**单行**的。服务端
 * （`server/lib/apns.ts` 的 `readAPNsConfigFromEnv`）会把字面量 `\n` 还原成真换行，
 * 所以环境变量里必须是 `-----BEGIN PRIVATE KEY-----\nMIGT...\n-----END PRIVATE KEY-----\n`。
 *
 * 手工用 `awk` 转义也行，但这个脚本多做三件 awk 做不到的事：
 *   1. **先把私钥真的解析一遍**（`createPrivateKey`）：少一个字符、多一个空格、
 *      把 `BEGIN RSA` 抄成 `BEGIN EC` —— 都在这里就报错，而不是等到线上
 *      只换来一条 `push_delivery.status=failed reason=InvalidKey`；
 *   2. 确认是 **EC P-256**（APNs 只认 ES256，别的曲线签出来的 JWT 一律被拒）；
 *   3. 验证**转义 → 还原**能逐字节回到原文（模拟服务端那次 `replace(/\\n/g, '\n')`）。
 *
 * ## 用法
 *   node scripts/apns-key.mjs ~/Downloads/AuthKey_ABC123DEFG.p8          # 打印单行值
 *   node scripts/apns-key.mjs ~/Downloads/AuthKey_ABC123DEFG.p8 --copy   # 直接进剪贴板（macOS）
 *
 * 打印出来的东西**就是密钥本身**：别贴进聊天、别提交进仓库。用完清掉终端滚动记录也不亏。
 */
import { execFileSync } from 'node:child_process'
import { createPrivateKey } from 'node:crypto'
import { readFileSync } from 'node:fs'

const USAGE = `用法：
  node scripts/apns-key.mjs <AuthKey_XXXXXXXXXX.p8>          打印单行转义值
  node scripts/apns-key.mjs <AuthKey_XXXXXXXXXX.p8> --copy   转义并复制到剪贴板（macOS）

拿到值之后填进环境变量 APNS_KEY_P8（Vercel 里直接粘贴，不要加引号）。
另外两个值是：APNS_KEY_ID = 文件名里的那 10 位、APNS_TEAM_ID = VX3SCAKB5K。
`

function fail(message) {
  console.error(`✗ ${message}`)
  process.exit(1)
}

const args = process.argv.slice(2)
const copyToClipboard = args.includes('--copy')
const file = args.find((arg) => !arg.startsWith('-'))

if (!file || args.includes('--help') || args.includes('-h')) {
  console.log(USAGE)
  process.exit(file ? 0 : 1)
}

let raw
try {
  raw = readFileSync(file, 'utf8')
} catch (error) {
  fail(`读不到文件：${file}（${error instanceof Error ? error.message : String(error)}）`)
}

// 1) 形状：必须是标准 PEM 的两行标记。\r\n 也容忍（从某些浏览器下载可能带 CRLF）
const lines = raw.replace(/\r\n/g, '\n').trim().split('\n')
if (lines[0] !== '-----BEGIN PRIVATE KEY-----') {
  fail(`第一行是 "${lines[0]}"，不是 "-----BEGIN PRIVATE KEY-----"。这不像 APNs 的 .p8（Apple 给的是未加密的 PKCS#8）。`)
}
if (lines.at(-1) !== '-----END PRIVATE KEY-----') {
  fail(`最后一行是 "${lines.at(-1)}"，不是 "-----END PRIVATE KEY-----"。文件可能被截断。`)
}

// 2) 能不能真的当私钥解析 —— 这一步能拦住绝大多数粘贴/复制事故
let key
try {
  key = createPrivateKey(lines.join('\n') + '\n')
} catch (error) {
  fail(`私钥解析失败：${error instanceof Error ? error.message : String(error)}`)
}

// 3) 必须是 EC P-256（APNs 的 ES256 只认 prime256v1）
if (key.asymmetricKeyType !== 'ec') {
  fail(`这是 ${key.asymmetricKeyType} 密钥，不是 EC。APNs 只接受 EC P-256（ES256）。`)
}
const curve = key.asymmetricKeyDetails?.namedCurve
if (curve && curve !== 'prime256v1') {
  fail(`曲线是 ${curve}，不是 prime256v1（P-256）。APNs 会拒。`)
}

// 4) 转义 + 回环校验（服务端做的是 value.replace(/\\n/g, '\n')，结果必须逐字节等于原文）
const escaped = lines.join('\\n') + '\\n'
const restored = escaped.replace(/\\n/g, '\n')
if (restored !== lines.join('\n') + '\n') {
  fail('转义后还原不回原文，脚本有 bug，别用这个值。')
}

// 5) 输出
const size = Buffer.byteLength(escaped, 'utf8')
const bodyChars = lines.slice(1, -1).join('').length

if (copyToClipboard) {
  try {
    execFileSync('pbcopy', { input: escaped })
  } catch {
    fail('pbcopy 失败（不是 macOS？）。去掉 --copy 直接打印吧。')
  }
  console.log('✓ 已复制到剪贴板。直接粘进 Vercel 的 APNS_KEY_P8，**不要加引号**。')
} else {
  console.log(escaped)
}

console.log('')
console.log('✓ 校验通过：')
console.log(`  · 私钥可解析，类型 EC（${curve ?? 'P-256'}）`)
console.log('  · 还原后与原文一致（服务端会把字面量 \\n 还原成真换行）')
console.log(`  · 单行长度 ${size} 字符（base64 主体 ${bodyChars} 字符）`)
console.log('')
console.log('接下来：')
console.log('  1. APNS_KEY_P8   ← 上面这个值（或已在剪贴板）')
console.log('  2. APNS_KEY_ID   ← 文件名 AuthKey_XXXXXXXXXX.p8 里的那 10 位')
console.log('  3. APNS_TEAM_ID  ← VX3SCAKB5K')
console.log('  4. 配完后在后台「偏好设置 → 推送」打开开关，再发一张照片验证')
