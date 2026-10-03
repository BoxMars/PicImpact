'use client'

import { Suspense } from 'react'
import { AppProgressBar } from 'next-nprogress-bar'

/**
 * 导航进度反馈。
 *
 * 原实现用 animal-island-ui 的 Loading（GSAP + MotionPathPlugin，构建后 88.8KB 原始 /
 * 36.0KB gzip）做一个 100vw×100vh、z-index 9999 的全屏虹膜遮罩，并强制最小显示时长：
 * 首屏 1000ms、每次客户端跳转 700ms（MIN_DISPLAY_MS）。它还在全局猴补丁了
 * window.history.pushState。实测这是"点哪都慢"的主要来源之一 —— 即使服务端瞬间返回，
 * 用户也要先看 0.7~1s 的过场动画。
 *
 * 现在换成 next-nprogress-bar 的 AppProgressBar：它是本站**已有**的依赖（此前只用了它的
 * useRouter，13 处），只有约 2KB，做一条顶部细进度条，**反映真实导航状态、没有任何
 * 人为最小显示时长**，也不再碰 history API。
 *
 * 注意：AppProgressBar 内部使用 useSearchParams，必须包 Suspense 边界。
 * startOnLoad 保持默认 false —— 首屏不应再有任何遮罩。
 */
export function ProgressBarProviders({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <Suspense fallback={null}>
        <AppProgressBar
          height="3px"
          color="#19c8b9"
          options={{ showSpinner: false }}
          shallowRouting
        />
      </Suspense>
    </>
  )
}
