'use client'

import { useEffect, useRef } from 'react'
import { ReloadIcon } from '@radix-ui/react-icons'

interface InfiniteScrollProps {
    hasMore: boolean
    isLoading: boolean
    next: () => void
    children: React.ReactNode
    className?: string
}

export default function InfiniteScroll({
    hasMore,
    isLoading,
    next,
    children,
    className,
}: InfiniteScrollProps) {
    const observerTarget = useRef<HTMLDivElement>(null)
    // 把最新的 props 放进 ref：调用方传的是内联箭头 `() => setSize(size + 1)`，
    // 每次渲染都是新引用。此前它出现在 effect 依赖里，导致每次渲染都
    // disconnect + observe 重建观察器，而 observe() 会立即投递一次 entry ——
    // 只要哨兵元素在视口内就会多发一次 setSize（多翻一页）。
    // 现在观察器只挂载一次，回调通过 ref 读最新值。
    const latest = useRef({ hasMore, isLoading, next })
    latest.current = { hasMore, isLoading, next }

    useEffect(() => {
        const el = observerTarget.current
        if (!el) return

        const observer = new IntersectionObserver(
            (entries) => {
                const { hasMore, isLoading, next } = latest.current
                if (entries[0]?.isIntersecting && hasMore && !isLoading) {
                    next()
                }
            },
            { threshold: 1.0 }
        )

        observer.observe(el)
        return () => observer.disconnect()
    }, [])

    return (
        <div className={className}>
            {children}
            <div ref={observerTarget} className="h-4 w-full flex items-center justify-center mt-4">
                {isLoading && (
                  <div style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    color: '#19c8b9',
                    fontWeight: 600,
                    fontSize: 13,
                    letterSpacing: '0.04em',
                  }}>
                    <ReloadIcon style={{ color: '#19c8b9', width: 16, height: 16 }} className="animate-spin" />
                    <span>加载中...</span>
                  </div>
                )}
            </div>
        </div>
    )
}
