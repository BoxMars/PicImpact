'use client'

import type { HandleProps, ImageHandleProps } from '~/types/props.ts'
import useSWRInfinite from 'swr/infinite'
import { useSwrHydrated } from '~/hooks/use-swr-hydrated.ts'
import { useTranslations } from 'next-intl'
import type { ImageType } from '~/types'
import GalleryImage from '~/components/gallery/simple/gallery-image.tsx'
import InfiniteScroll from '~/components/ui/origin/infinite-scroll.tsx'
import { MasonryGrid } from '~/components/ui/origin/masonry-grid'
import { useCallback, useEffect, useMemo, useRef, useState, useTransition } from 'react'
import useSWR from 'swr'
import { Title, Divider, Footer, Time, Icon, Typewriter } from 'animal-island-ui'

export default function SimpleGallery(props: Readonly<ImageHandleProps>) {
  const [selectedCamera, setSelectedCamera] = useState('')
  const [selectedLens, setSelectedLens] = useState('')
  const [debouncedCamera, setDebouncedCamera] = useState('')
  const [debouncedLens, setDebouncedLens] = useState('')
  const [, startTransition] = useTransition()

  const { data: pageTotal } = useSWR(
    [`pageTotal-${props.args}-${props.album}`, debouncedCamera, debouncedLens],
    () => props.totalHandle(props.album, debouncedCamera || undefined, debouncedLens || undefined),
    {
      revalidateOnFocus: false,
      revalidateIfStale: false,
      revalidateOnReconnect: false,
      keepPreviousData: true,
      fallbackData: props.initialPageTotal,
    }
  )

  const { data, isValidating, size, setSize } = useSWRInfinite(
    (index) => [`client-${props.args}-${index}-${props.album}-${debouncedCamera}-${debouncedLens}`, index],
    ([, index]) => props.handle(index + 1, props.album, debouncedCamera || undefined, debouncedLens || undefined),
    {
      revalidateOnFocus: false,
      revalidateIfStale: false,
      revalidateOnReconnect: false,
      keepPreviousData: true,
      fallbackData: props.initialImages ? [props.initialImages] : undefined,
    }
  )

  const configProps: HandleProps = { handle: props.configHandle, args: 'system-config' }
  const { data: configData } = useSwrHydrated(configProps, props.initialConfigData)
  const dataList = useMemo(() => data ? [].concat(...data) : [], [data])
  const t = useTranslations()

  useEffect(() => {
    const timer = setTimeout(() => {
      startTransition(() => {
        setDebouncedCamera(selectedCamera)
        setDebouncedLens(selectedLens)
      })
    }, 150)
    return () => clearTimeout(timer)
  }, [selectedCamera, selectedLens])

  const prevFiltersRef = useRef({ camera: '', lens: '' })
  useEffect(() => {
    const prev = prevFiltersRef.current
    if (prev.camera !== debouncedCamera || prev.lens !== debouncedLens) {
      prevFiltersRef.current = { camera: debouncedCamera, lens: debouncedLens }
      if (size > 1) setSize(1)
    }
  }, [debouncedCamera, debouncedLens, size, setSize])

  const handleCameraChange = useCallback((camera: string) => setSelectedCamera(camera), [])
  const handleLensChange = useCallback((lens: string) => setSelectedLens(lens), [])

  return (
    <>
      {/* Island header */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '2.5rem 1rem 0.5rem', gap: 12, position: 'relative' }}>
        {/* AC clock top-right — hidden on mobile */}
        <div className="hidden xl:block" style={{ position: 'absolute', top: 24, right: 24 }}>
          <Time />
        </div>

        {/* Critterpedia icon + title */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Icon name="icon-critterpedia" size={28} bounce />
          <Title size="large" color="app-pink">大福映画 Felina Gallery</Title>
          <Icon name="icon-camera" size={28} bounce />
        </div>

        {/* Typewriter subtitle */}
        <Typewriter speed={60}>
          <p style={{ color: '#9f927d', fontSize: 14, fontWeight: 500, letterSpacing: '0.04em' }}>
            光と影で綴る、パパとママと私の物語。
          </p>
        </Typewriter>

        {/* Nook Miles style photo counter */}
        {dataList.length > 0 && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, background: 'rgb(247,243,223)', border: '1.5px solid #c4b89e', borderRadius: 20, padding: '4px 14px', boxShadow: '0 2px 0 0 #bdaea0' }}>
            <Icon name="icon-miles" size={18} />
            <span style={{ fontSize: 12, fontWeight: 800, color: '#725d42', letterSpacing: '0.04em' }}>
              {dataList.length} 张照片已收集
            </span>
          </div>
        )}
      </div>

      <Divider type="wave-yellow" style={{ margin: '0.75rem 0 0' }} />

      <InfiniteScroll
        className="w-full"
        hasMore={size < pageTotal}
        isLoading={isValidating}
        next={() => setSize(size + 1)}
      >
        {/* Masonry waterfall grid — constrained width, 3 columns, side padding */}
        <div className="px-3 sm:px-6 md:px-10"
          style={{ maxWidth: 1280, margin: '0 auto', paddingTop: 16, paddingBottom: 16 }}
        >
        {/* 行优先瀑布流：CSS 多列是列优先的（先填满第 1 列再填第 2 列），
            会让按时间排序的照片变成「一列读到底」。改用 Grid（默认行优先）
            + 逐项按实测高度跨行，既保参差高度又让相邻照片并排。 */}
        <MasonryGrid className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4">
          {dataList?.map((item: ImageType, idx: number) => (
            <div key={item.id} className="masonry-item">
              {/* Island card */}
              <div
                className="island-simple-card"
                style={{
                  borderRadius: 18,
                  background: 'rgb(247, 243, 223)',
                  border: '2px solid #c4b89e',
                  boxShadow: '0 3px 0 0 #bdaea0, 0 4px 16px rgba(121,79,39,0.08)',
                  transition: 'box-shadow 0.25s ease, transform 0.25s ease',
                  contain: 'layout style',
                }}
              >
                <GalleryImage photo={item} configData={configData} priority={idx < 4} />
              </div>
            </div>
          ))}
        </MasonryGrid>
        </div>

        {dataList.length === 0 && !isValidating && (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '60px 20px', gap: 16, color: '#9f927d' }}>
            <div style={{ display: 'flex', gap: 16, fontSize: 40 }}>
              <span className="ac-leaf">🍃</span>
              <span style={{ fontSize: 56 }}>🏝</span>
              <span className="ac-leaf" style={{ animationDelay: '1s' }}>🌺</span>
            </div>
            <Icon name="icon-critterpedia" size={48} bounce />
            <p style={{ fontSize: 16, fontWeight: 700, letterSpacing: '0.02em', color: '#794f27' }}>{t('Tips.noImg')}</p>
            <Typewriter speed={50}>
              <p style={{ fontSize: 13, fontWeight: 500 }}>小岛上还没有照片，快去拍一张吧！🌿</p>
            </Typewriter>
          </div>
        )}
      </InfiniteScroll>

      <div style={{ marginBottom: 80 }}>
        <Footer type="tree" />
      </div>
    </>
  )
}
