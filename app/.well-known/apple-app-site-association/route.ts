import { NextResponse } from 'next/server'

/**
 * Apple 关联域名文件：让系统把**保存的密码**关联到这个 App（AutoFill 的正规机制）。
 *
 * 规范要点（缺一条系统就不认）：
 * - 路径固定 `/.well-known/apple-app-site-association`，**无扩展名**
 * - `Content-Type: application/json`
 * - **不得重定向**，必须 HTTPS 直接 200
 * - apps 元素是 `"<TeamID>.<bundle id>"`
 *
 * 为什么用 route handler 而不是往 public/ 放静态文件：静态文件没有扩展名时，
 * Next 会按 `application/octet-stream` 发出去，而 Apple 要求 JSON。这里显式定类型。
 *
 * ⚠️ 与 App 侧的 entitlement 必须**同时**存在才生效：
 * `ios/FelinaGallery/FelinaGallery.entitlements` 里的 `webcredentials:felina.boxz.dev`。
 */
const TEAM_ID = 'VX3SCAKB5K'
const BUNDLE_ID = 'dev.boxz.felina'

// 纯静态内容：不要因为读了什么而变成动态渲染
export const dynamic = 'force-static'

export function GET() {
  return NextResponse.json(
    { webcredentials: { apps: [`${TEAM_ID}.${BUNDLE_ID}`] } },
    { headers: { 'Cache-Control': 'public, max-age=3600' } }
  )
}
