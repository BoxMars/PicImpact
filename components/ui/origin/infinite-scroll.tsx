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

    useEffect(() => {
        const observer = new IntersectionObserver(
            (entries) => {
                if (entries[0]?.isIntersecting && hasMore && !isLoading) {
                    next()
                }
            },
            { threshold: 1.0 }
        )

        if (observerTarget.current) {
            observer.observe(observerTarget.current)
        }

        return () => observer.disconnect()
    }, [hasMore, isLoading, next])

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
