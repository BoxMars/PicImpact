'use client'

import type { ImageType } from '~/types'
import { toast } from 'sonner'
import { RefreshCWIcon } from '~/components/icons/refresh-cw.tsx'
import { cn } from '~/lib/utils'
import PreviewImageExif from '~/components/album/preview-image-exif.tsx'
import useSWR from 'swr'
import type { ImageDataProps } from '~/types/props.ts'
import { useRouter } from 'next-nprogress-bar'
import { useBlurImageDataUrl, DEFAULT_HASH } from '~/hooks/use-blurhash.ts'
import { MotionImage } from '~/components/album/motion-image'
import { Skeleton } from '~/components/ui/skeleton'
import { memo, useEffect, useState, type CSSProperties } from 'react'
import { isProxyImageUrl, toProxyImageUrl } from '~/lib/utils/image-proxy'
import { formatExifDateTimeForDisplay } from '~/lib/utils/exif-time'
import { Icon } from 'animal-island-ui'

// 提到模块级：避免每个方块每次渲染都新建样式对象（也避免 React 反复 diff 同一组字面量）
const exifChipStyle: CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 3,
  color: '#9f927d',
  fontSize: 11,
  fontWeight: 600,
  cursor: 'default',
}

const iconActionStyle: CSSProperties = {
  cursor: 'pointer',
  display: 'inline-flex',
  alignItems: 'center',
}

function GalleryImage({ photo, configData, priority = false }: { photo: ImageType, configData: any, priority?: boolean }) {
  const router = useRouter()

  const { data: download = false, mutate: setDownload } = useSWR(['masonry/download', photo?.url ?? ''], null)
  const [thumbLoading, setThumbLoading] = useState(true)

  const dataURL = useBlurImageDataUrl(photo.blurhash)
  const exifProps: ImageDataProps = { data: photo }

  // 网格只消费 preview_url（缩略图）。原图仅在预览页按需加载。
  // 曾经这里会在挂载时预取 photo.url（全分辨率原图）并叠成一层图层：实测首屏 24 张
  // 卡片因此多下载 82.73MB 原图，并对每张做两次全分辨率解码 —— 这是滚动掉帧的主因。
  const thumbUrl = photo.preview_url || photo.url || ''
  const proxyThumb = toProxyImageUrl(thumbUrl)

  const [resolvedThumb, setResolvedThumb] = useState(proxyThumb || thumbUrl)

  useEffect(() => {
    setResolvedThumb(proxyThumb || thumbUrl)
    setThumbLoading(true)
  }, [thumbUrl, proxyThumb])

  async function downloadImg() {
    setDownload(true)
    try {
      let msg = '开始下载，原图较大，请耐心等待！'
      if (photo?.album_license != null) {
        msg += '图片版权归作者所有, 分享转载需遵循 ' + photo.album_license + ' 许可协议！'
      }
      toast.warning(msg, { duration: 1500 })
      const storageType = photo?.url?.includes('s3') ? 's3' : 'r2'
      let response = await fetch(`/api/public/download/${photo.id}?storage=${storageType}`)
      const contentType = response.headers.get('content-type')
      if (contentType?.includes('application/json')) {
        const data = await response.json()
        response = await fetch(data.url)
      }
      const blob = await response.blob()
      const url = window.URL.createObjectURL(new Blob([blob]))
      const link = document.createElement('a')
      link.href = url
      const parsedUrl = new URL(photo?.url ?? '')
      const filename = parsedUrl.pathname.split('/').pop()
      link.download = filename || 'downloaded-file.jpg'
      document.body.appendChild(link)
      link.click()
      document.body.removeChild(link)
    } catch (e) {
      toast.error('下载失败！', { duration: 500 })
    } finally {
      setDownload(false)
    }
  }

  const hasExif = photo?.exif?.make || photo?.exif?.f_number || photo?.exif?.exposure_time ||
    photo?.exif?.focal_length || photo?.exif?.iso_speed_rating

  return (
    <div style={{ display: 'flex', flexDirection: 'column' }}>
      {/* Image — full card width, progressive loading */}
      <div
        style={{ position: 'relative', width: '100%', cursor: 'pointer', borderRadius: '16px 16px 0 0', overflow: 'hidden' }}
        onClick={() => router.push(`/preview/${photo?.id}`)}
      >
{(photo.blurhash === DEFAULT_HASH || !photo.blurhash) && thumbLoading && (
          <Skeleton className="absolute inset-0 z-10 rounded-none" />
        )}

        {/* Thumbnail (bottom layer) */}
        <MotionImage
          className={cn(thumbLoading && 'animate-pulse')}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 0.6 }}
          src={resolvedThumb}
          overrideSrc={resolvedThumb}
          alt={photo.title}
          width={photo.width}
          height={photo.height}
          // 首屏前几张标记为高优先级，其余惰性加载。此前全仓库没有任何 priority，
          // 导致 LCP 图片和视口外图片同一起跑线。
          loading={priority ? 'eager' : 'lazy'}
          fetchPriority={priority ? 'high' : 'auto'}
          unoptimized
          placeholder={(photo.blurhash === DEFAULT_HASH || !photo.blurhash) ? 'empty' : 'blur'}
          blurDataURL={dataURL}
          onLoad={() => setThumbLoading(false)}
          onError={() => {
            if (isProxyImageUrl(resolvedThumb) && thumbUrl) {
              setResolvedThumb(thumbUrl)
              return
            }
            setThumbLoading(false)
          }}
        />

        {photo.type === 2 && (
          <div
            style={{
              position: 'absolute',
              top: 8,
              left: 8,
              background: 'rgba(247,243,223,0.92)',
              border: '1.5px solid #c4b89e',
              borderRadius: 20,
              padding: '2px 8px',
              fontSize: 10,
              fontWeight: 700,
              color: '#725d42',
              letterSpacing: '0.05em',
              backdropFilter: 'blur(4px)',
            }}
          >
            LIVE
          </div>
        )}
      </div>

      {/* Card info */}
      <div style={{ padding: '10px 14px 12px', display: 'flex', flexDirection: 'column', gap: 6 }}>

        {/* Title + date */}
        {(photo.title || photo?.exif?.data_time) && (
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}>
            {photo.title && (
              <span style={{ fontWeight: 700, color: '#794f27', fontSize: 13, lineHeight: 1.4, flex: 1, minWidth: 0 }}>
                {photo.title}
              </span>
            )}
            {photo?.exif?.data_time && (
              <span style={{ color: '#c4b89e', fontSize: 10, fontWeight: 600, whiteSpace: 'nowrap', flexShrink: 0 }}>
                {formatExifDateTimeForDisplay(photo.exif.data_time)}
              </span>
            )}
          </div>
        )}

        {/* Description */}
        {photo?.detail && (
          <p style={{ color: '#9f927d', fontSize: 12, lineHeight: 1.5, margin: 0 }}>
            {photo.detail}
          </p>
        )}

        {/* EXIF row —— 用原生 `title` 替代 animal-island-ui Tooltip。
            库里的 Tooltip 即使隐藏也会渲染约 12 个元素（含 2 个 SVG，path d 长 709 字符），
            每方块 9 个 = 约 108 个额外节点；240 张时约 2160 个 clipPath 与约 3MB 重复 SVG 文本。
            换成原生 title 后每方块 DOM 节点从约 130 降到约 20。 */}
        {hasExif && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 10px', marginTop: 2 }}>
            {photo?.exif?.make && photo?.exif?.model && (
              <span title="相机" style={exifChipStyle}>
                <Icon name="icon-camera" size={14} style={{ flexShrink: 0 }} />
                {photo.exif.make} {photo.exif.model}
              </span>
            )}
            {photo?.exif?.f_number && (
              <span title="光圈" style={exifChipStyle}>
                <Icon name="icon-variant" size={14} style={{ flexShrink: 0 }} />
                {photo.exif.f_number}
              </span>
            )}
            {photo?.exif?.exposure_time && (
              <span title="曝光时间" style={exifChipStyle}>
                <Icon name="icon-miles" size={14} style={{ flexShrink: 0 }} />
                {photo.exif.exposure_time}
              </span>
            )}
            {photo?.exif?.focal_length && (
              <span title="焦距" style={exifChipStyle}>
                <Icon name="icon-map" size={14} style={{ flexShrink: 0 }} />
                {parseFloat(photo.exif.focal_length).toFixed(0)}mm
              </span>
            )}
            {photo?.exif?.iso_speed_rating && (
              <span title="感光度 ISO" style={exifChipStyle}>
                <Icon name="icon-critterpedia" size={14} style={{ flexShrink: 0 }} />
                ISO {photo.exif.iso_speed_rating}
              </span>
            )}
          </div>
        )}

        {/* Tags */}
        {photo?.labels && photo.labels.length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginTop: 2 }}>
            {photo.labels.map((tag: string) => (
              <span
                key={tag}
                onClick={() => router.push(`/tag/${tag}`)}
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  padding: '1px 8px',
                  borderRadius: 20,
                  fontSize: 10,
                  fontWeight: 700,
                  letterSpacing: '0.03em',
                  cursor: 'pointer',
                  background: '#e6f9f6',
                  border: '1.5px solid #19c8b9',
                  color: '#19c8b9',
                  userSelect: 'none',
                }}
              >
                🏷 {tag}
              </span>
            ))}
          </div>
        )}

        {/* Separator + actions —— 同上，改用原生 title */}
        <div style={{ height: 1, background: '#c4b89e', opacity: 0.35, margin: '2px 0' }} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, height: 24 }}>
          <span title="复制图片链接" style={iconActionStyle} onClick={async () => {
            try {
              await navigator.clipboard.writeText(photo?.url ?? '')
              let msg = '复制图片链接成功！'
              if (photo?.album_license != null) msg = '图片版权归作者所有, 分享转载需遵循 ' + photo?.album_license + ' 许可协议！'
              toast.success(msg, { duration: 1500 })
            } catch { toast.error('复制图片链接失败！', { duration: 500 }) }
          }}>
            <Icon name="icon-diy" size={18} />
          </span>
          <span title="复制分享直链" style={iconActionStyle} onClick={async () => {
            try {
              await navigator.clipboard.writeText(window.location.origin + '/preview/' + photo.id)
              toast.success('复制分享直链成功！', { duration: 500 })
            } catch { toast.error('复制分享直链失败！', { duration: 500 }) }
          }}>
            <Icon name="icon-helicopter" size={18} />
          </span>
          {configData?.find((item: any) => item.config_key === 'custom_index_download_enable')?.config_value.toString() === 'true' && (
            download
              ? <RefreshCWIcon style={{ color: '#c4b89e' }} className={cn('animate-spin cursor-not-allowed')} size={18} />
              : (
                <span title="下载原图" style={iconActionStyle} onClick={() => downloadImg()}>
                  <Icon name="icon-shopping" size={18} />
                </span>
              )
          )}
          <span title="查看 EXIF 信息" style={iconActionStyle}><PreviewImageExif {...exifProps} /></span>
        </div>
      </div>
    </div>
  )
}

export default memo(GalleryImage)
