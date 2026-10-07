import { rgbaToThumbHash } from 'thumbhash'
import sharp from 'sharp'

/**
 * 图片转 ThumbHash（本站 `images.blurhash` 字段里存的就是它），返回 base64 字符串。
 *
 * 算法与浏览器端 `lib/utils/blurhash-client.ts` 的 `encodeBrowserThumbHash` 一致：
 * 先等比缩到最长边 100，再 `rgbaToThumbHash`，最后 base64。
 * 参考 https://github.com/evanw/thumbhash/blob/main/examples/node/index.js
 *
 * ## 为什么服务端也算这个（原本只有浏览器算）
 * 服务端为了生成缩略图**已经下载了原图字节**（`server/lib/preview-storage.ts`），
 * 顺路多跑一次 100px 缩放是 ~10ms 的事，却换来"同一张图在 web 与 App 上 blurhash 完全一致"。
 * 这是 Review Focus 3/4 的裁决：图像派生元数据（预览图 / 宽高 / blurhash）统一由服务端产出。
 *
 * 注：本模块原先带 `import 'server-only'`。它现在被 `server/lib/preview-storage.ts` 使用，
 * 而后者刻意不带 server-only（迁移脚本与单测要在纯 Node/tsx 下跑，带那个包会直接抛错）。
 * 客户端保护由依赖本身提供：sharp 与 thumbhash 都无法在浏览器里打包。
 *
 * @param image 原图字节
 */
export const encodeThumbHash = async (image: Buffer | Uint8Array): Promise<string> => {
  const imageBuffer = Buffer.isBuffer(image) ? image : Buffer.from(image)
  const { data, info } = await sharp(imageBuffer, { failOn: 'none' })
    .resize(100, 100, { fit: 'inside' })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const hash = rgbaToThumbHash(info.width, info.height, data)
  return Buffer.from(hash).toString('base64')
}
