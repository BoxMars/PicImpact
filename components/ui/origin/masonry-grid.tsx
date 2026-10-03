'use client'

import { useEffect, useRef, useState } from 'react'

/** 网格行高粒度（px）。越小越贴合，但生成的隐式行轨也越多。8 是贴合度与开销的折中。 */
const ROW = 8
/** 卡片之间的视觉垂直间距（px），由跨行数里多留的行实现。 */
const GAP = 16
const GAP_ROWS = Math.ceil(GAP / ROW)

/**
 * 行优先的瀑布流网格。
 *
 * 原先用的是 CSS 多列（`columns-1 sm:columns-2 lg:columns-3`）。CSS 多列是**列优先**的：
 * 浏览器先把第 1 列从上到下填满，再填第 2 列 —— 于是按拍摄时间排序的照片变成
 * 「一列读到底」，相邻的两张在视觉上是上下关系而不是左右关系。
 *
 * 这里改用 CSS Grid：
 * - `grid-auto-flow` 默认为 `row`，所以放置顺序天然是**行优先**（左→右、上→下），
 *   且与 DOM 顺序一致（键盘/读屏顺序也对）；
 * - 每一项再用 `grid-row-end: span N` 按其**实际渲染高度**跨行，因此仍保留参差高度
 *   （真正的瀑布流），并且追加数据时已有项不会跳到别的列。
 *
 * 为什么需要测量：卡片高度 = 图片（按原比例，尺寸已知）+ 下方信息块（标题/日期/描述/
 * EXIF/标签/操作，高度不定）。只有图片那部分能从宽高比推算，所以信息块的高度必须实测。
 *
 * 首帧策略：水合前不加 `gridAutoRows`，容器此时是普通等高行网格（顺序已经正确、不会重叠），
 * 待测量完成后再切换为 `8px` 行高 + 逐项跨行，贴合为瀑布流。这样避免「先给出错误的跨行
 * 数导致卡片互相重叠」。
 */
export function MasonryGrid({
  children,
  className,
}: {
  children: React.ReactNode
  className?: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [measured, setMeasured] = useState(false)

  useEffect(() => {
    const el = ref.current
    if (!el) return

    let raf = 0
    const apply = () => {
      cancelAnimationFrame(raf)
      raf = requestAnimationFrame(() => {
        const items = Array.from(el.children) as HTMLElement[]
        for (const item of items) {
          const h = item.getBoundingClientRect().height
          if (!h) continue
          // 多留 GAP_ROWS 行作为与下一项的视觉间距
          const next = `span ${Math.ceil(h / ROW) + GAP_ROWS}`
          if (item.style.gridRowEnd !== next) item.style.gridRowEnd = next
        }
        setMeasured(true)
      })
    }

    apply()

    // 观察每个子项：图片加载完成、字体切换、文案变化都会改变高度，需要重新贴合。
    // 同时观察容器：响应式列数变化会改变每项宽度，从而改变高度。
    const itemObserver = new ResizeObserver(apply)
    const observeItems = () =>
      (Array.from(el.children) as HTMLElement[]).forEach((c) => itemObserver.observe(c))
    observeItems()

    const containerObserver = new ResizeObserver(apply)
    containerObserver.observe(el)

    // 追加分页后子项会变化，用 MutationObserver 重新挂观察
    const mutationObserver = new MutationObserver(() => {
      observeItems()
      apply()
    })
    mutationObserver.observe(el, { childList: true })

    return () => {
      cancelAnimationFrame(raf)
      itemObserver.disconnect()
      containerObserver.disconnect()
      mutationObserver.disconnect()
    }
  }, [])

  return (
    <div
      ref={ref}
      className={className}
      style={{
        // `alignItems: 'start'` 不是样式偏好，而是**正确性前提**：网格项默认
        // `align-items: stretch`，会被拉伸填满自己的网格区域；那样测到的高度就把
        // 「为间距多留的行」也算进去，下一轮 span 再变大 → ResizeObserver 正反馈，
        // 每轮长 GAP 像素直至失控（实测曾把 180px 的块撑到 3448px）。
        // 改成 start 后项高 = 内容高，span 只在其下方留出间距，测量收敛。
        alignItems: 'start',
        ...(measured ? { gridAutoRows: `${ROW}px`, rowGap: 0 } : { rowGap: GAP }),
      }}
    >
      {children}
    </div>
  )
}
