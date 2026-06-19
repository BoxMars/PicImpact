'use client'

import { Loading } from 'animal-island-ui'
import { useEffect, useRef, useState } from 'react'
import { usePathname } from 'next/navigation'
import { flushSync } from 'react-dom'

const MIN_DISPLAY_MS = 700

export function ProgressBarProviders({ children }: { children: React.ReactNode }) {
  const [active, setActive] = useState(true)
  const pathname = usePathname()
  const initialized = useRef(false)
  const showAt = useRef<number>(Date.now())
  const hideTimer = useRef<ReturnType<typeof setTimeout>>()

  const scheduleHide = () => {
    clearTimeout(hideTimer.current)
    const elapsed = Date.now() - showAt.current
    const delay = Math.max(0, MIN_DISPLAY_MS - elapsed)
    hideTimer.current = setTimeout(() => setActive(false), delay)
  }

  // Initial page load
  useEffect(() => {
    showAt.current = Date.now()
    hideTimer.current = setTimeout(() => {
      setActive(false)
      initialized.current = true
    }, 1000)
    return () => clearTimeout(hideTimer.current)
  }, [])

  // Navigation complete → hide after min display time
  useEffect(() => {
    if (!initialized.current) return
    scheduleHide()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pathname])

  // Intercept navigation start
  useEffect(() => {
    const origPush = window.history.pushState.bind(window.history)

    window.history.pushState = (...args: Parameters<typeof window.history.pushState>) => {
      // flushSync forces React to render active=true before navigation continues,
      // preventing batching with the subsequent pathname-change setActive(false)
      flushSync(() => {
        showAt.current = Date.now()
        setActive(true)
      })
      return origPush(...args)
    }

    const onPop = () => {
      showAt.current = Date.now()
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
      <div
        style={{
          position: 'fixed',
          top: 0,
          left: 0,
          width: '100vw',
          height: '100vh',
          zIndex: 9999,
          pointerEvents: active ? 'auto' : 'none',
        }}
      >
        <Loading active={active} />
      </div>
      {children}
    </>
  )
}
