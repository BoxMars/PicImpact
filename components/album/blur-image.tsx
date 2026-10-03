'use client'

import { useRouter } from 'next-nprogress-bar'
import { useBlurImageDataUrl, DEFAULT_HASH } from '~/hooks/use-blurhash'
import { MotionImage } from '~/components/album/motion-image'
import { Skeleton } from '~/components/ui/skeleton'
import { memo, useEffect, useState } from 'react'
import { cn } from '~/lib/utils'
// hovered state removed — hover handled purely via CSS (.island-blur-image:hover)
import { isProxyImageUrl, toProxyImageUrl } from '~/lib/utils/image-proxy'

function BlurImage({ photo, dataList: _dataList }: { photo: any, dataList: any }) {
  const router = useRouter()
  const [isLoading, setIsLoading] = useState(true)
  const rawSrc = photo?.src || ''
  const proxySrc = toProxyImageUrl(rawSrc)
  const [resolvedSrc, setResolvedSrc] = useState(proxySrc || rawSrc)

  const dataURL = useBlurImageDataUrl(photo.blurhash)

  useEffect(() => {
    setResolvedSrc(proxySrc || rawSrc)
    setIsLoading(true)
  }, [proxySrc, rawSrc])

  return (
    <div className="island-blur-image">
      {isLoading && (
        <Skeleton className="absolute inset-0 z-10 rounded-none" />
      )}
      <MotionImage
        className={cn(isLoading && 'animate-pulse')}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 0.8 }}
        src={resolvedSrc}
        alt={photo.alt}
        width={photo.width}
        height={photo.height}
        loading="lazy"
        // 交给 next/image 优化（理由见 gallery-image.tsx）。
        // 瀑布流容器是 w-[66.667%]，2/3/4 列 → 大屏每列约 200~320px。
        sizes="(max-width: 768px) 50vw, (max-width: 1024px) 33vw, 25vw"
        placeholder={(photo.blurhash === DEFAULT_HASH || !photo.blurhash) ? 'empty' : 'blur'}
        blurDataURL={dataURL}
        onClick={() => router.push(`/preview/${photo?.id}`)}
        onLoad={() => setIsLoading(false)}
        onError={() => {
          if (isProxyImageUrl(resolvedSrc) && rawSrc) {
            setResolvedSrc(rawSrc)
            return
          }
          setIsLoading(false)
        }}
      />
      {photo.type === 2 && (
        <div className="island-live-badge">LIVE</div>
      )}
      <div className="island-hover-shimmer" />
    </div>
  )
}

// memo 生效的前提是 `photo` 引用稳定 —— default-gallery 里已按 dataList 记忆化。
// `dataList` 只被透传且不使用，比较时忽略。
export default memo(BlurImage, (prev, next) => prev.photo === next.photo)
