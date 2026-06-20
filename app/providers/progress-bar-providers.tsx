'use client'

import { Loading } from 'animal-island-ui'
import { useEffect, useRef, useState } from 'react'
import { usePathname } from 'next/navigation'

const MIN_DISPLAY_MS = 700
// Duration of the iris-close animation (matches animal-island-ui internals: d/1500 s)
const getIrisDuration = () => {
  if (typeof window === 'undefined') return 1000
  const d = Math.ceil(Math.hypot(window.innerWidth, window.innerHeight) / 2) + 50
  return Math.max(100, (d / 1500) * 1000) + 150
}

export function ProgressBarProviders({ children }: { children: React.ReactNode }) {
  const [active, setActive] = useState(true)
  // mounted controls whether GSAP animation is in DOM at all; unmount after iris closes
  const [mounted, setMounted] = useState(true)
  const pathname = usePathname()
  const initialized = useRef(false)
  const showAt = useRef<number>(Date.now())
  const hideTimer = useRef<ReturnType<typeof setTimeout>>()
  const unmountTimer = useRef<ReturnType<typeof setTimeout>>()

  const scheduleHide = () => {
    clearTimeout(hideTimer.current)
    clearTimeout(unmountTimer.current)
    const elapsed = Date.now() - showAt.current
    const delay = Math.max(0, MIN_DISPLAY_MS - elapsed)
    hideTimer.current = setTimeout(() => {
      setActive(false)
      // Unmount after iris-close animation finishes → stops GSAP from running at 60fps
      unmountTimer.current = setTimeout(() => setMounted(false), getIrisDuration())
    }, delay)
  }

  // Initial page load
  useEffect(() => {
    showAt.current = Date.now()
    hideTimer.current = setTimeout(() => {
      setActive(false)
      initialized.current = true
      unmountTimer.current = setTimeout(() => setMounted(false), getIrisDuration())
    }, 1000)
    return () => {
      clearTimeout(hideTimer.current)
      clearTimeout(unmountTimer.current)
    }
  }, [])

  // Navigation complete → hide after min display time
  useEffect(() => {
    if (!initialized.current) return
    scheduleHide()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pathname])

  // Intercept navigation start → mount + show immediately
  useEffect(() => {
    const origPush = window.history.pushState.bind(window.history)

    window.history.pushState = (...args: Parameters<typeof window.history.pushState>) => {
      clearTimeout(unmountTimer.current)
      showAt.current = Date.now()
      setMounted(true)
      queueMicrotask(() => setActive(true))
      return origPush(...args)
    }

    const onPop = () => {
      clearTimeout(unmountTimer.current)
      showAt.current = Date.now()
      setMounted(true)
      setActive(true)
    }
    window.addEventListener('popstate', onPop)

    return () => {
      window.history.pushState = origPush
      window.removeEventListener('popstate', onPop)
    }
  }, [])

  return (
    <>
      {mounted && (
        <div
          style={{
            position: 'fixed',
            top: 0,
            left: 0,
            width: '100vw',
            height: '100vh',
            zIndex: 9999,
            pointerEvents: active ? 'auto' : 'none',
            willChange: 'transform',
            transform: 'translateZ(0)',
            isolation: 'isolate',
          }}
        >
          <Loading active={active} />
        </div>
      )}
      {children}
    </>
  )
}
