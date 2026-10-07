/**
 * 首页顶部的 App Store 横幅。
 *
 * 设计约束（Apple 的品牌规范）：
 *   * 使用**官方徽章**，不可改造、不可重新配色、不可只取局部；
 *     所以这里直接用 public/brand 下自托管的官方 SVG（1284×… 不对，是官方 108.85:40 比例），
 *     只按比例缩放，不加滤镜、不裁剪。
 *   * 徽章四周留出净空，背景保持简洁（这里是米白纸色，对比足够）。
 *
 * 配色沿用站点设计体系的三个值：纸色 #F7F3DF、描边 #C4B89E、文字 #725D42。
 * 这里用内联样式而不是 Tailwind 类名，是为了让组件自成一体、不依赖设计系统里
 * 具体类名的拼写。
 */
const APP_STORE_URL = 'https://apps.apple.com/cn/app/id6819038230'

export function AppStoreBanner() {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 14,
        flexWrap: 'wrap',
        padding: '10px 16px',
        background: '#F7F3DF',
        borderBottom: '1px solid #C4B89E',
      }}
    >
      <span style={{ color: '#725D42', fontSize: 13, lineHeight: 1.4 }}>
        「大福映画」已上架 App Store
      </span>
      <a
        href={APP_STORE_URL}
        target="_blank"
        rel="noopener noreferrer"
        aria-label="在 App Store 下载大福映画"
        style={{ display: 'inline-flex', lineHeight: 0 }}
      >
        {/* 官方中文（简体）黑色徽章，原始比例 108.85157 : 40 */}
        <img
          src="/brand/appstore-badge-zh-black.svg"
          alt="Download on the App Store"
          width={131}
          height={48}
          style={{ display: 'block', width: 131, height: 'auto' }}
        />
      </a>
    </div>
  )
}

export default AppStoreBanner
