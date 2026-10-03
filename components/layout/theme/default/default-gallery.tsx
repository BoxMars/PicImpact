'use client'

import type { ImageHandleProps } from '~/types/props.ts'
import useSWRInfinite from 'swr/infinite'
import useSWR from 'swr'
import { useTranslations } from 'next-intl'
import type { ImageType } from '~/types'
import { useState, useCallback, useEffect, useRef, useMemo, useTransition } from 'react'
import { MasonryPhotoAlbum, RenderImageContext, RenderImageProps } from 'react-photo-album'
import BlurImage from '~/components/album/blur-image.tsx'
import InfiniteScroll from '~/components/ui/origin/infinite-scroll.tsx'
import { Title, Divider, Footer, Time, Icon, Typewriter } from 'animal-island-ui'

function renderNextImage(
  _: RenderImageProps,
  { photo }: RenderImageContext,
  dataList: never[],
) {
  return (
    <BlurImage photo={photo} dataList={dataList} />
  )
}

export default function DefaultGallery(props: Readonly<ImageHandleProps>) {
  const [selectedCamera, setSelectedCamera] = useState('')
  const [selectedLens, setSelectedLens] = useState('')
  const [debouncedCamera, setDebouncedCamera] = useState('')
  const [debouncedLens, setDebouncedLens] = useState('')
  const [, startTransition] = useTransition()

  const { data, isValidating, size, setSize } = useSWRInfinite(
    (index) => {
      return [`client-${props.args}-${index}-${props.album}-${debouncedCamera}-${debouncedLens}`, index]
    },
    ([, index]) => {
      return props.handle(index + 1, props.album, debouncedCamera || undefined, debouncedLens || undefined)
    },
    {
      revalidateOnFocus: false,
      revalidateIfStale: false,
      revalidateOnReconnect: false,
      keepPreviousData: true,
      fallbackData: props.initialImages ? [props.initialImages] : undefined,
    }
  )

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

  const dataList = useMemo(() => data ? [].concat(...data) : [], [data])
  // react-photo-album 用 photos 数组的**引用**作为 useMemo 依赖来计算瀑布流布局
  // （node_modules/react-photo-album/dist/client/masonry.js 的 [photos, ...]），
  // 而内联 `.map()` 每次渲染都产生新数组 → 每次父组件渲染都会重算布局并重渲染
  // 全部已加载方块。`render` 对象同理。两者都按 dataList 记忆化。
  const photos = useMemo(
    () => (dataList ?? []).map((item: ImageType) => ({
      src: item.preview_url || item.url,
      alt: item.detail,
      key: item.id,
      ...item,
    })),
    [dataList],
  )
  const render = useMemo(
    () => ({ image: (...args: any[]) => renderNextImage(args[0], args[1], dataList as never[]) }),
    [dataList],
  )
  const t = useTranslations()
  const prevFiltersRef = useRef({ camera: '', lens: '' })

  useEffect(() => {
    const timer = setTimeout(() => {
      startTransition(() => {
        setDebouncedCamera(selectedCamera)
        setDebouncedLens(selectedLens)
      })
    }, 150)
    return () => clearTimeout(timer)
  }, [selectedCamera, selectedLens])

  useEffect(() => {
    const prev = prevFiltersRef.current
    if (prev.camera !== debouncedCamera || prev.lens !== debouncedLens) {
      prevFiltersRef.current = { camera: debouncedCamera, lens: debouncedLens }
      if (size > 1) {
        setSize(1)
      }
    }
  }, [debouncedCamera, debouncedLens, size, setSize])

  const handleCameraChange = useCallback((camera: string) => {
    setSelectedCamera(camera)
  }, [])

  const handleLensChange = useCallback((lens: string) => {
    setSelectedLens(lens)
  }, [])

  return (
    <>
      {/* Island header */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '2.5rem 1rem 0.5rem', gap: 12, position: 'relative' }}>
        {/* AC clock */}
        <div className="hidden xl:block" style={{ position: 'absolute', top: 24, right: 24 }}>
          <Time />
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <Icon name="icon-map" size={36} bounce />
          <Title size="large" color="app-teal">大福映画 Felina Gallery</Title>
          <Icon name="icon-camera" size={36} bounce />
        </div>

        <Typewriter speed={55}>
          <p style={{ color: '#9f927d', fontSize: 14, fontWeight: 500, letterSpacing: '0.04em' }}>
            光と影で綴る、パパとママと私の物語。
          </p>
        </Typewriter>

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
        className="w-full p-2 space-y-4"
        hasMore={size < pageTotal}
        isLoading={isValidating}
        next={() => setSize(size + 1)}
      >
        <div className="flex flex-col sm:flex-row w-full p-2 items-start justify-between sm:relative overflow-x-clip">
          <div className="flex flex-1 flex-col px-2 sm:sticky top-4 self-start" />
          <div className="w-full sm:w-[66.667%] mx-auto">
            {/* defaultContainerWidth 让 react-photo-album 在服务端就能算出布局：
            该库默认要等客户端测量容器宽度，于是首屏 HTML 里一个瓦片都没有
            （实测相册页 SSR 出来的 <img> 数为 0）。给了默认宽度后首屏即可渲染瓦片，
            客户端测量完成后会再校正一次。900px 对应桌面端 66.667% 容器下的 3 列。 */}
            <MasonryPhotoAlbum
              defaultContainerWidth={900}
              columns={(containerWidth) => {
                if (containerWidth < 768) return 2
                if (containerWidth < 1024) return 3
                return 4
              }}
              photos={photos}
              render={render}
            />
          </div>
          <div className="flex flex-wrap space-x-2 sm:space-x-0 sm:flex-col flex-1 px-2 py-1 sm:py-0 space-y-1 sm:sticky top-4 self-start" />
        </div>
        {dataList.length === 0 && !isValidating && (
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '60px 20px',
              gap: 12,
              color: '#9f927d',
            }}
          >
            <span style={{ fontSize: 48 }}>🏝</span>
            <p style={{ fontSize: 16, fontWeight: 600, letterSpacing: '0.02em' }}>
              {t('Tips.noImg')}
            </p>
            <p style={{ fontSize: 13, fontWeight: 500 }}>小岛上还没有照片，快去拍一张吧！</p>
          </div>
        )}
      </InfiniteScroll>

      <div style={{ marginBottom: 80 }}>
        <Footer type="sea" />
      </div>
    </>
  )
}
