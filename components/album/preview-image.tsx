'use client'

import type { HandleProps, PreviewImageHandleProps } from '~/types/props'
import LivePhoto from '~/components/album/live-photo'
import { toast } from 'sonner'
import useSWR from 'swr'
import { useRouter } from 'next-nprogress-bar'
import { RefreshCWIcon } from '~/components/icons/refresh-cw'
import { cn } from '~/lib/utils'
import { useSwrHydrated } from '~/hooks/use-swr-hydrated'
import { useMemo, useState } from 'react'
import { useTranslations } from 'next-intl'
import ProgressiveImage from '~/components/album/progressive-image.tsx'
import ToneAnalysis from '~/components/album/tone-analysis'
import HistogramChart from '~/components/album/histogram-chart'
import { ScrollArea } from '~/components/ui/scroll-area'
import { formatExifDateTimeForDisplay } from '~/lib/utils/exif-time'
import { Icon, Tooltip, Divider } from 'animal-island-ui'

function Row({ label, value }: { label: string; value: string | number | null | undefined }) {
  if (!value) return null
  return (
    <div className="flex justify-between gap-4 text-sm">
      <span className="shrink-0" style={{ color: '#9f927d', fontWeight: 500 }}>{label}</span>
      <span className="min-w-0 text-right" style={{ color: '#725d42', fontWeight: 600 }}>{value}</span>
    </div>
  )
}

function ParamBadge({ icon, value, label }: { icon: React.ReactNode; value: string; label: string }) {
  return (
    <Tooltip title={label} variant="island" placement="top">
      <div
        style={{
          display: 'flex',
          width: '100%',
          height: 32,
          alignItems: 'center',
          gap: 6,
          borderRadius: 16,
          border: '1.5px solid #c4b89e',
          background: 'rgb(247, 243, 223)',
          padding: '0 12px',
          cursor: 'default',
          boxShadow: '0 2px 0 0 #bdaea0',
        }}
      >
        {icon}
        <span style={{ fontSize: 11, color: '#725d42', fontWeight: 700 }}>{value}</span>
      </div>
    </Tooltip>
  )
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <h4 style={{ marginBottom: 8, fontSize: 11, fontWeight: 800, letterSpacing: '0.06em', color: '#19c8b9', textTransform: 'uppercase' }}>
      {children}
    </h4>
  )
}

function ActionBtn({ name, label, onClick }: { name: any; label: string; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'inline-flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 4,
        background: 'none',
        border: 'none',
        padding: '4px 6px',
        cursor: 'pointer',
      }}
    >
      <span
        style={{
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          width: 38, height: 38, borderRadius: 50,
          border: '1.5px solid #c4b89e', background: 'rgb(247,243,223)',
          boxShadow: '0 2px 0 0 #bdaea0', transition: 'all 0.18s ease',
        }}
        onMouseEnter={e => {
          (e.currentTarget as HTMLElement).style.borderColor = '#19c8b9'
          ;(e.currentTarget as HTMLElement).style.boxShadow = '0 2px 0 0 #19c8b9'
          ;(e.currentTarget as HTMLElement).style.transform = 'translateY(-2px)'
        }}
        onMouseLeave={e => {
          (e.currentTarget as HTMLElement).style.borderColor = '#c4b89e'
          ;(e.currentTarget as HTMLElement).style.boxShadow = '0 2px 0 0 #bdaea0'
          ;(e.currentTarget as HTMLElement).style.transform = 'translateY(0)'
        }}
      >
        <Icon name={name} size={20} />
      </span>
      <span style={{ fontSize: 10, fontWeight: 700, color: '#9f927d', letterSpacing: '0.02em', whiteSpace: 'nowrap' }}>
        {label}
      </span>
    </button>
  )
}

export default function PreviewImage(props: Readonly<PreviewImageHandleProps>) {
  const router = useRouter()
  const t = useTranslations()
  const { data: download = false, mutate: setDownload } = useSWR(['masonry/download', props.data?.url ?? ''], null)

  const configProps: HandleProps = { handle: props.configHandle, args: 'system-config' }
  const { data: configData } = useSwrHydrated(configProps)
  const customAuthor = configData?.find((item: any) => item.config_key === 'custom_author')?.config_value
  const currentYear = new Date().getFullYear()
  const copyrightYears = `2024-${currentYear}`

  const formattedDateTime = useMemo(() => {
    if (!props.data?.exif?.data_time) return null
    return formatExifDateTimeForDisplay(props.data.exif.data_time)
  }, [props.data?.exif?.data_time])

  const dimensions = useMemo(() => {
    if (props.data?.width && props.data?.height) return `${props.data.width} × ${props.data.height}`
    return null
  }, [props.data?.width, props.data?.height])

  const megaPixels = useMemo(() => {
    if (props.data?.width && props.data?.height) return `${((props.data.width * props.data.height) / 1_000_000).toFixed(1)} MP`
    return null
  }, [props.data?.width, props.data?.height])

  const imageUrl = props.data?.preview_url || props.data?.url || ''

  const handleClose = () => {
    if (window?.history.length > 1) { router.back(); return }
    router.push(props.data?.album_value ? `${props.data.album_value}` : '/')
  }

  const handleDownload = async () => {
    setDownload(true)
    try {
      let msg = t('Tips.downloadStart')
      if (props.data?.album_license != null) msg += t('Tips.downloadLicense', { license: props.data.album_license })
      toast.warning(msg, { duration: 1500 })
      const storageType = props.data?.url?.includes('s3') ? 's3' : 'r2'
      let response = await fetch(`/api/public/download/${props.id}?storage=${storageType}`)
      const contentType = response.headers.get('content-type')
      if (contentType?.includes('application/json')) {
        const data = await response.json()
        const filename = decodeURIComponent(data.filename || 'download.jpg')
        response = await fetch(data.url)
        const blob = await response.blob()
        const url = window.URL.createObjectURL(new Blob([blob]))
        const link = document.createElement('a')
        link.href = url; link.download = filename
        document.body.appendChild(link); link.click(); document.body.removeChild(link)
      } else {
        const contentDisposition = response.headers.get('content-disposition')
        let filename = 'download'
        if (contentDisposition) {
          const m = contentDisposition.match(/filename="([^"]+)"/)
          if (m) filename = decodeURIComponent(m[1])
        }
        const blob = await response.blob()
        const url = window.URL.createObjectURL(new Blob([blob]))
        const link = document.createElement('a')
        link.href = url; link.download = filename
        document.body.appendChild(link); link.click(); document.body.removeChild(link)
      }
    } catch { toast.error(t('Tips.downloadFailed'), { duration: 500 }) }
    finally { setDownload(false) }
  }

  if (!props.data) {
    return (
      <div className="flex items-center justify-center h-full">
        <p style={{ color: '#9f927d' }}>{t('Tips.loading')}</p>
      </div>
    )
  }

  return (
    <div className="flex flex-col overflow-y-auto scrollbar-hide h-full rounded-none! max-w-none gap-0 p-2">
      <div className="relative flex flex-col space-y-2 sm:h-full sm:grid sm:gap-4 sm:grid-cols-3 w-full">

        {/* Left: photo — natural aspect ratio on mobile, height-constrained on desktop */}
        <div className="sm:col-span-2 sm:flex sm:justify-center sm:max-h-[90vh] select-none">
          {props.data.type === 1
            ? <ProgressiveImage
                imageUrl={props.data.url}
                previewUrl={props.data.preview_url}
                alt={props.data.title}
                height={props.data.height}
                width={props.data.width}
                blurhash={props.data.blurhash}
              />
            : <LivePhoto
                url={props.data.preview_url || props.data.url}
                videoUrl={props.data.video_url}
                className="md:h-[90vh] md:max-h-[90vh]"
              />
          }
        </div>

        {/* Right: island info panel */}
        <ScrollArea className="sm:max-h-[90vh] scrollbar-hide">
          <div
            style={{
              background: 'rgb(247,243,223)',
              border: '2px solid #c4b89e',
              borderRadius: 18,
              boxShadow: '0 4px 0 0 #bdaea0, 0 6px 20px rgba(121,79,39,0.10)',
              padding: '16px 16px 12px',
              display: 'flex',
              flexDirection: 'column',
              gap: 14,
            }}
          >
            {/* Title + close */}
            <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 }}>
              <div style={{ flex: 1, fontWeight: 800, fontSize: 16, color: '#794f27', letterSpacing: '0.01em', lineHeight: 1.4 }}>
                {props.data?.title}
              </div>
              <button
                onClick={handleClose}
                style={{
                  flexShrink: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                  width: 30, height: 30, borderRadius: 50, border: '1.5px solid #c4b89e',
                  background: 'rgb(247,243,223)', cursor: 'pointer', fontSize: 13, boxShadow: '0 2px 0 0 #bdaea0',
                }}
                title={t('Button.goBack')}
              >
                ✕
              </button>
            </div>

            {/* Action buttons — inline label under icon, no tooltip needed */}
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              <ActionBtn name="icon-diy" label="复制链接" onClick={async () => {
                try {
                  await navigator.clipboard.writeText(props.data?.url ?? '')
                  let msg = t('Tips.copyImageSuccess')
                  if (props.data?.album_license != null) msg = t('Tips.downloadLicense', { license: props.data.album_license })
                  toast.success(msg, { duration: 1500 })
                } catch { toast.error(t('Tips.copyImageFailed'), { duration: 500 }) }
              }} />
              <ActionBtn name="icon-chat" label="分享直链" onClick={async () => {
                try {
                  await navigator.clipboard.writeText(window.location.origin + '/preview/' + props.id)
                  toast.success(t('Tips.copyShareSuccess'), { duration: 500 })
                } catch { toast.error(t('Tips.copyShareFailed'), { duration: 500 }) }
              }} />
              {configData?.find((item: any) => item.config_key === 'custom_index_download_enable')?.config_value.toString() === 'true' && (
                download
                  ? <div style={{ display: 'inline-flex', flexDirection: 'column', alignItems: 'center', gap: 4, padding: '4px 6px' }}>
                      <RefreshCWIcon className={cn('animate-spin')} style={{ color: '#c4b89e' }} size={20} />
                      <span style={{ fontSize: 10, color: '#9f927d', fontWeight: 700 }}>下载原图</span>
                    </div>
                  : <ActionBtn name="icon-shopping" label="下载原图" onClick={handleDownload} />
              )}
            </div>

            <Divider type="dashed-teal" />

            {/* Basic info */}
            <div>
              <SectionTitle>{t('Exif.basicInfo')}</SectionTitle>
              <div className="space-y-1.5">
                {dimensions && <Row label={t('Exif.dimensions')} value={dimensions} />}
                {megaPixels && <Row label={t('Exif.pixels')} value={megaPixels} />}
                <Row label={t('Exif.captureTime')} value={formattedDateTime} />
              </div>
            </div>

            {/* Capture params */}
            {(props.data?.exif?.focal_length || props.data?.exif?.f_number ||
              props.data?.exif?.exposure_time || props.data?.exif?.iso_speed_rating) && (
              <div>
                <SectionTitle>{t('Exif.captureParams')}</SectionTitle>
                <div className="grid grid-cols-2 gap-2">
                  {props.data.exif?.focal_length && (
                    <ParamBadge icon={<Icon name="icon-map" size={14} />} value={parseFloat(props.data.exif.focal_length).toFixed(2) + ' mm'} label="焦距" />
                  )}
                  {props.data.exif?.f_number && (
                    <ParamBadge icon={<Icon name="icon-variant" size={14} />} value={props.data.exif.f_number} label="光圈" />
                  )}
                  {props.data.exif?.exposure_time && (
                    <ParamBadge icon={<Icon name="icon-miles" size={14} />} value={props.data.exif.exposure_time} label="曝光时间" />
                  )}
                  {props.data.exif?.iso_speed_rating && (
                    <ParamBadge icon={<Icon name="icon-critterpedia" size={14} />} value={`ISO ${props.data.exif.iso_speed_rating}`} label="感光度" />
                  )}
                </div>
              </div>
            )}

            {/* Device info */}
            {(props.data?.exif?.make || props.data?.exif?.model || props.data?.exif?.lens_model) && (
              <div>
                <SectionTitle>{t('Exif.deviceInfo')}</SectionTitle>
                <div className="space-y-1.5">
                  {props.data.exif?.make && props.data.exif?.model && (
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <Icon name="icon-camera" size={14} />
                      <span style={{ fontSize: 13, color: '#725d42', fontWeight: 600 }}>{props.data.exif.make} {props.data.exif.model}</span>
                    </div>
                  )}
                  {props.data.exif?.lens_model && (
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <Icon name="icon-design" size={14} />
                      <span style={{ fontSize: 13, color: '#725d42', fontWeight: 600 }}>{props.data.exif.lens_model}</span>
                    </div>
                  )}
                  {props.data.exif?.focal_length && (
                    <Row label={t('Exif.focalLength')} value={parseFloat(props.data.exif.focal_length).toFixed(2) + ' mm'} />
                  )}
                </div>
              </div>
            )}

            {/* Capture mode */}
            {(props.data?.exif?.exposure_mode || props.data?.exif?.exposure_program || props.data?.exif?.white_balance) && (
              <div>
                <SectionTitle>{t('Exif.captureMode')}</SectionTitle>
                <div className="space-y-1">
                  {props.data.exif?.exposure_program && <Row label={t('Exif.exposureProgram')} value={props.data.exif.exposure_program} />}
                  <Row label={t('Exif.exposureMode')} value={props.data?.exif?.exposure_mode} />
                  <Row label={t('Exif.whiteBalance')} value={props.data?.exif?.white_balance} />
                </div>
              </div>
            )}

            {/* Technical params */}
            {(props.data?.exif?.bits || props.data?.exif?.cfa_pattern) && (
              <div>
                <SectionTitle>{t('Exif.technicalParams')}</SectionTitle>
                <div className="space-y-1">
                  {props.data.exif?.bits && <Row label={t('Exif.bitDepth')} value={props.data.exif.bits} />}
                  {props.data.exif?.cfa_pattern && <Row label={t('Exif.cfaPattern')} value={props.data.exif.cfa_pattern} />}
                </div>
              </div>
            )}

            {/* Tone analysis */}
            {imageUrl && (
              <div>
                <SectionTitle>{t('Exif.toneAnalysis')}</SectionTitle>
                <ToneAnalysis imageUrl={imageUrl} />
              </div>
            )}

            {/* Histogram */}
            {imageUrl && (
              <div>
                <SectionTitle>{t('Exif.histogram')}</SectionTitle>
                <HistogramChart imageUrl={imageUrl} />
              </div>
            )}

            {/* Tags */}
            {props.data?.labels && props.data.labels.length > 0 && (
              <div>
                <SectionTitle>{t('Exif.tags')}</SectionTitle>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                  {props.data.labels.map((tag: string) => (
                    <span
                      key={tag}
                      onClick={() => router.push(`/tag/${tag}`)}
                      style={{
                        display: 'inline-flex', alignItems: 'center',
                        padding: '2px 10px', borderRadius: 20,
                        fontSize: 11, fontWeight: 700, letterSpacing: '0.03em',
                        cursor: 'pointer', background: '#e6f9f6',
                        border: '1.5px solid #19c8b9', color: '#19c8b9', userSelect: 'none',
                      }}
                    >
                      🏷 {tag}
                    </span>
                  ))}
                </div>
              </div>
            )}

            {/* Description */}
            {props.data?.detail && (
              <div style={{ display: 'flex', alignItems: 'flex-start', gap: 6 }}>
                <Icon name="icon-chat" size={14} style={{ flexShrink: 0, marginTop: 2 }} />
                <p style={{ fontSize: 13, color: '#725d42', fontWeight: 500, lineHeight: 1.6 }}>
                  {props.data.detail}
                </p>
              </div>
            )}

            <Divider type="dashed-brown" />

            {/* Copy EXIF + copyright — extra bottom padding clears the fixed dock */}
            <div style={{ paddingBottom: 80 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <button
                style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: '#9f927d', fontWeight: 700, cursor: 'pointer', background: 'none', border: 'none', padding: 0, letterSpacing: '0.02em' }}
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText(JSON.stringify(props.data?.exif, null, 2))
                    toast.success(t('Exif.copySuccess'), { duration: 1500 })
                  } catch { toast.error(t('Exif.copyFailed'), { duration: 500 }) }
                }}
              >
                <Icon name="icon-diy" size={14} />
                <span>{t('Exif.copyExif')}</span>
              </button>
              <span style={{ fontSize: 10, color: '#c4b89e', fontWeight: 600 }}>
                © {copyrightYears} {customAuthor || '大福映画 Felina Gallery'}
              </span>
            </div>
            </div>{/* end paddingBottom wrapper */}
          </div>
        </ScrollArea>
      </div>
    </div>
  )
}
