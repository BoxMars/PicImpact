'use client'

import type { ProgressiveImageProps } from '~/types/props.ts'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslations } from 'next-intl'
import { MotionImage } from '~/components/album/motion-image'
import { useBlurImageDataUrl } from '~/hooks/use-blurhash'
import { WebGLImageViewer } from '~/components/album/webgl-viewer'
import type { WebGLImageViewerRef } from '~/components/album/webgl-viewer'
import { isWebGLSupported } from '~/lib/utils/webgl'
import { isProxyImageUrl, toProxyImageUrl } from '~/lib/utils/image-proxy'

/**
 * 渐进式图片展示组件，支持 WebGL 高性能渲染
 * - 首先显示预览图
 * - 后台预加载原始图片
 * - 加载完成后显示高清图并支持全屏查看
 */
export default function ProgressiveImage(
  props: Readonly<ProgressiveImageProps>,
) {
  const t = useTranslations()

  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [highResImageLoaded, setHighResImageLoaded] = useState(false)
  const [showFullScreenViewer, setShowFullScreenViewer] = useState(Boolean(props.showLightbox))
  const [webGLAvailable] = useState(() => isWebGLSupported())

  const webglViewerRef = useRef<WebGLImageViewerRef | null>(null)
  const previewRawSrc = props.previewUrl || ''
  const highResRawSrc = props.imageUrl || ''
  const previewProxySrc = useMemo(() => toProxyImageUrl(previewRawSrc), [previewRawSrc])
  const highResProxySrc = useMemo(() => toProxyImageUrl(highResRawSrc), [highResRawSrc])
  const [resolvedPreviewSrc, setResolvedPreviewSrc] = useState(previewProxySrc || previewRawSrc)
  const [resolvedHighResSrc, setResolvedHighResSrc] = useState(highResProxySrc || highResRawSrc)

  useEffect(() => {
    return () => {
      webglViewerRef.current?.destroy()
    }
  }, [])

  useEffect(() => {
    setShowFullScreenViewer(Boolean(props.showLightbox))
  }, [props.showLightbox])

  useEffect(() => {
    setResolvedPreviewSrc(previewProxySrc || previewRawSrc)
  }, [previewProxySrc, previewRawSrc])

  useEffect(() => {
    let cancelled = false

    const loadImage = (src: string) => new Promise<boolean>((resolve) => {
      if (!src) {
        resolve(false)
        return
      }

      const image = new window.Image()
      image.decoding = 'async'
      image.src = src

      image.onload = async () => {
        try {
          if (typeof image.decode === 'function') {
            await image.decode()
          }
        } catch {
          // Ignore decode errors and fallback to onload status.
        }
        resolve(true)
      }

      image.onerror = () => resolve(false)
    })

    const preloadImage = async () => {
      setIsLoading(true)
      setError(null)
      setHighResImageLoaded(false)

      if (!highResRawSrc) {
        setError(t('Tips.imageLoadFailed'))
        setIsLoading(false)
        return
      }

      const proxyLoaded = await loadImage(highResProxySrc)
      const fallbackLoaded = proxyLoaded ? true : await loadImage(highResRawSrc)

      if (cancelled) {
        return
      }

      if (fallbackLoaded) {
        setResolvedHighResSrc(proxyLoaded ? highResProxySrc : highResRawSrc)
        setHighResImageLoaded(true)
        setIsLoading(false)
      } else {
        setError(t('Tips.imageLoadFailed'))
        setIsLoading(false)
      }
    }

    void preloadImage()

    return () => {
      cancelled = true
    }
  }, [highResProxySrc, highResRawSrc, t])

  const dataURL = useBlurImageDataUrl(props.blurhash)

  const handleCloseViewer = () => {
    setShowFullScreenViewer(false)
    if (props.onShowLightboxChange) {
      props.onShowLightboxChange(false)
    }
  }

  return (
    <div className="relative">
      {!highResImageLoaded && (
        <MotionImage
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 1 }}
          className="object-contain md:max-h-[90vh]"
          src={resolvedPreviewSrc}
          overrideSrc={resolvedPreviewSrc}
          placeholder="blur"
          unoptimized
          blurDataURL={dataURL}
          width={props.width}
          height={props.height}
          alt={props.alt || 'image'}
          onError={() => {
            if (isProxyImageUrl(resolvedPreviewSrc) && previewRawSrc) {
              setResolvedPreviewSrc(previewRawSrc)
            }
          }}
        />
      )}

      {isLoading && (
        <div className="absolute bottom-2 right-2 rounded bg-black/60 px-2 py-1 text-xs text-white">
          Loading original...
        </div>
      )}

      {error && (
        <div className="absolute bottom-2 right-2 rounded bg-black/60 px-2 py-1 text-xs text-white">
          {error}
        </div>
      )}

      {highResImageLoaded && !showFullScreenViewer && (
        <img
          className="object-contain md:max-h-[90vh]"
          src={resolvedHighResSrc}
          width={props.width}
          height={props.height}
          alt={props.alt || 'image'}
          loading="eager"
          decoding="async"
          onError={() => {
            if (isProxyImageUrl(resolvedHighResSrc) && highResRawSrc) {
              setResolvedHighResSrc(highResRawSrc)
              return
            }
            setError(t('Tips.imageLoadFailed'))
          }}
        />
      )}

      {showFullScreenViewer ? (
        webGLAvailable ? (
          <div
            className="fixed inset-0 z-[100] flex items-center justify-center bg-black/90"
            onClick={(e) => {
              if (e.target === e.currentTarget) {
                handleCloseViewer()
              }
            }}
          >
            <button
              onClick={handleCloseViewer}
              className="absolute right-4 top-4 z-[110] rounded-full bg-white/10 p-2 transition-colors hover:bg-white/20"
              aria-label={t('Button.close')}
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="text-white"
              >
                <line x1="18" y1="6" x2="6" y2="18"></line>
                <line x1="6" y1="6" x2="18" y2="18"></line>
              </svg>
            </button>

            <div className="pointer-events-none absolute bottom-4 left-1/2 -translate-x-1/2 text-sm text-white/50">
              {t('Tips.zoomHint')}
            </div>

            <div className="h-full w-full">
              <WebGLImageViewer
                ref={webglViewerRef}
                src={resolvedHighResSrc}
                width={props.width}
                height={props.height}
                className="h-full w-full"
                initialScale={1}
                minScale={0.5}
                maxScale={10}
                limitToBounds={true}
                smooth={true}
                debug={process.env.NODE_ENV === 'development'}
              />
            </div>
          </div>
        ) : (
          <div
            className="fixed inset-0 z-[100] flex items-center justify-center overflow-auto bg-black/90"
            onClick={(e) => {
              if (e.target === e.currentTarget) {
                handleCloseViewer()
              }
            }}
          >
            <button
              onClick={handleCloseViewer}
              className="absolute right-4 top-4 z-[110] rounded-full bg-white/10 p-2 transition-colors hover:bg-white/20"
              aria-label={t('Button.close')}
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="text-white"
              >
                <line x1="18" y1="6" x2="6" y2="18"></line>
                <line x1="6" y1="6" x2="18" y2="18"></line>
              </svg>
            </button>

            <div className="absolute left-4 top-4 rounded bg-black/50 px-3 py-1 text-sm text-white/70">
              {t('Tips.webglUnavailable')}
            </div>

            <img
              className="max-h-full max-w-full object-contain"
              src={resolvedHighResSrc}
              alt={props.alt || 'image'}
              loading="eager"
              decoding="async"
            />
          </div>
        )
      ) : null}
    </div>
  )
}
