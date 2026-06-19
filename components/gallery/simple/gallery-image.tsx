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
import { useEffect, useState } from 'react'
import { isProxyImageUrl, toProxyImageUrl } from '~/lib/utils/image-proxy'
import { formatExifDateTimeForDisplay } from '~/lib/utils/exif-time'
import { Icon, Tooltip } from 'animal-island-ui'

export default function GalleryImage({ photo, configData }: { photo: ImageType, configData: any }) {
  const router = useRouter()

  const { data: download = false, mutate: setDownload } = useSWR(['masonry/download', photo?.url ?? ''], null)
  const [thumbLoading, setThumbLoading] = useState(true)
  const [hdLoaded, setHdLoaded] = useState(false)

  const dataURL = useBlurImageDataUrl(photo.blurhash)
  const exifProps: ImageDataProps = { data: photo }

  const thumbUrl = photo.preview_url || photo.url || ''
  const hdUrl = photo.url || photo.preview_url || ''
  const proxyThumb = toProxyImageUrl(thumbUrl)
  const proxyHd = toProxyImageUrl(hdUrl)

  const [resolvedThumb, setResolvedThumb] = useState(proxyThumb || thumbUrl)
  const [resolvedHd, setResolvedHd] = useState(proxyHd || hdUrl)

  useEffect(() => {
    setResolvedThumb(proxyThumb || thumbUrl)
    setResolvedHd(proxyHd || hdUrl)
    setThumbLoading(true)
    setHdLoaded(false)
  }, [thumbUrl, hdUrl])

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
          loading="lazy"
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

        {/* HD original (top layer, fades in) */}
        {resolvedHd && resolvedHd !== resolvedThumb && (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={resolvedHd}
            alt={photo.title}
            width={photo.width}
            height={photo.height}
            style={{
              position: 'absolute',
              inset: 0,
              width: '100%',
              height: '100%',
              objectFit: 'cover',
              opacity: hdLoaded ? 1 : 0,
              transition: 'opacity 0.8s ease',
            }}
            onLoad={() => setHdLoaded(true)}
            onError={() => {
              if (isProxyImageUrl(resolvedHd) && hdUrl) setResolvedHd(hdUrl)
            }}
          />
        )}

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

        {/* HD badge — shows when HD is loaded */}
        {hdLoaded && (
          <div
            style={{
              position: 'absolute',
              top: 8,
              right: 8,
              background: 'rgba(25,200,185,0.85)',
              borderRadius: 20,
              padding: '2px 7px',
              fontSize: 9,
              fontWeight: 800,
              color: '#fff',
              letterSpacing: '0.06em',
            }}
          >
            HD
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

        {/* EXIF row */}
        {hasExif && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 10px', marginTop: 2 }}>
            {photo?.exif?.make && photo?.exif?.model && (
              <Tooltip title="相机" variant="island" placement="top">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: '#9f927d', fontSize: 11, fontWeight: 600, cursor: 'default' }}>
                  <Icon name="icon-camera" size={14} style={{ flexShrink: 0 }} />
                  {photo.exif.make} {photo.exif.model}
                </span>
              </Tooltip>
            )}
            {photo?.exif?.f_number && (
              <Tooltip title="光圈" variant="island" placement="top">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: '#9f927d', fontSize: 11, fontWeight: 600, cursor: 'default' }}>
                  <Icon name="icon-variant" size={14} style={{ flexShrink: 0 }} />
                  {photo.exif.f_number}
                </span>
              </Tooltip>
            )}
            {photo?.exif?.exposure_time && (
              <Tooltip title="曝光时间" variant="island" placement="top">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: '#9f927d', fontSize: 11, fontWeight: 600, cursor: 'default' }}>
                  <Icon name="icon-miles" size={14} style={{ flexShrink: 0 }} />
                  {photo.exif.exposure_time}
                </span>
              </Tooltip>
            )}
            {photo?.exif?.focal_length && (
              <Tooltip title="焦距" variant="island" placement="top">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: '#9f927d', fontSize: 11, fontWeight: 600, cursor: 'default' }}>
                  <Icon name="icon-map" size={14} style={{ flexShrink: 0 }} />
                  {parseFloat(photo.exif.focal_length).toFixed(0)}mm
                </span>
              </Tooltip>
            )}
            {photo?.exif?.iso_speed_rating && (
              <Tooltip title="感光度 ISO" variant="island" placement="top">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: '#9f927d', fontSize: 11, fontWeight: 600, cursor: 'default' }}>
                  <Icon name="icon-critterpedia" size={14} style={{ flexShrink: 0 }} />
                  ISO {photo.exif.iso_speed_rating}
                </span>
              </Tooltip>
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

        {/* Separator + actions */}
        <div style={{ height: 1, background: '#c4b89e', opacity: 0.35, margin: '2px 0' }} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, height: 24 }}>
          <Tooltip title="复制图片链接" variant="island" placement="top">
            <span style={{ cursor: 'pointer', display: 'inline-flex', alignItems: 'center' }} onClick={async () => {
              try {
                await navigator.clipboard.writeText(photo?.url ?? '')
                let msg = '复制图片链接成功！'
                if (photo?.album_license != null) msg = '图片版权归作者所有, 分享转载需遵循 ' + photo?.album_license + ' 许可协议！'
                toast.success(msg, { duration: 1500 })
              } catch { toast.error('复制图片链接失败！', { duration: 500 }) }
            }}>
              <Icon name="icon-diy" size={18} />
            </span>
          </Tooltip>
          <Tooltip title="复制分享直链" variant="island" placement="top">
            <span style={{ cursor: 'pointer', display: 'inline-flex', alignItems: 'center' }} onClick={async () => {
              try {
                await navigator.clipboard.writeText(window.location.origin + '/preview/' + photo.id)
                toast.success('复制分享直链成功！', { duration: 500 })
              } catch { toast.error('复制分享直链失败！', { duration: 500 }) }
            }}>
              <Icon name="icon-helicopter" size={18} />
            </span>
          </Tooltip>
          {configData?.find((item: any) => item.config_key === 'custom_index_download_enable')?.config_value.toString() === 'true' && (
            download
              ? <RefreshCWIcon style={{ color: '#c4b89e' }} className={cn('animate-spin cursor-not-allowed')} size={18} />
              : (
                <Tooltip title="下载原图" variant="island" placement="top">
                  <span style={{ cursor: 'pointer', display: 'inline-flex', alignItems: 'center' }} onClick={() => downloadImg()}>
                    <Icon name="icon-shopping" size={18} />
                  </span>
                </Tooltip>
              )
          )}
          <Tooltip title="查看 EXIF 信息" variant="island" placement="top">
            <span style={{ display: 'inline-flex', alignItems: 'center' }}><PreviewImageExif {...exifProps} /></span>
          </Tooltip>
        </div>
      </div>
    </div>
  )
}
