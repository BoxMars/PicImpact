'use client'

import type { ImageHandleProps } from '~/types/props'
import { useSwrPageTotalHook } from '~/hooks/use-swr-page-total-hook'
import useSWRInfinite from 'swr/infinite'
import { useTranslations } from 'next-intl'
import { MasonryPhotoAlbum, RenderImageContext, RenderImageProps } from 'react-photo-album'
import type { ImageType } from '~/types'
import { ReloadIcon } from '@radix-ui/react-icons'
import { Button, Title, Divider } from 'animal-island-ui'
import BlurImage from '~/components/album/blur-image'
import { useRouter } from 'next-nprogress-bar'

function renderNextImage(
  _: RenderImageProps,
  { photo }: RenderImageContext,
  dataList: never[],
) {
  return (
    <BlurImage photo={photo} dataList={dataList} />
  )
}

export default function TagGallery(props: Readonly<ImageHandleProps>) {
  const { data: pageTotal } = useSwrPageTotalHook(props)
  const { data, isLoading, isValidating, size, setSize } = useSWRInfinite((index) => {
    return [`client-${props.args}-${index}-${props.album}`, index]
  },
    ([_, index]) => {
      return props.handle(index + 1, props.album, undefined, undefined)
    }, {
    revalidateOnFocus: false,
    revalidateIfStale: false,
    revalidateOnReconnect: false,
    fallbackData: props.initialImages ? [props.initialImages] : undefined,
  })
  const dataList = data ? [].concat(...data) : []
  const t = useTranslations()
  const router = useRouter()

  return (
    <div className="w-full p-2 space-y-4">
      {/* Island tag header */}
      <div
        style={{
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          padding: '2rem 1rem 0.5rem',
          gap: 12,
        }}
      >
        <Title size="middle" color="app-yellow">🏷 {props.album}</Title>
        <button
          onClick={() => router.back()}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            padding: '4px 16px',
            borderRadius: 20,
            border: '1.5px solid #c4b89e',
            background: 'rgb(247, 243, 223)',
            color: '#9f927d',
            fontSize: 12,
            fontWeight: 600,
            cursor: 'pointer',
            letterSpacing: '0.02em',
            transition: 'all 0.2s ease',
          }}
        >
          ← {t('Button.goBack')}
        </button>
      </div>

      <Divider type="dashed-teal" style={{ margin: '0' }} />

      <div className="flex flex-col sm:flex-row w-full p-2 items-start justify-between sm:relative overflow-x-clip">
        <div className="order-3 sm:order-1 flex flex-1 flex-col px-2 sm:sticky top-4 self-start" />
        <div className="order-2 w-full sm:w-[66.667%] mx-auto">
          <MasonryPhotoAlbum
            columns={(containerWidth) => {
              if (containerWidth < 768) return 2
              if (containerWidth < 1024) return 3
              return 4
            }}
            photos={
              dataList?.map((item: ImageType) => ({
                src: item.preview_url || item.url,
                alt: item.detail,
                ...item
              })) || []
            }
            render={{ image: (...args) => renderNextImage(...args, dataList) }}
          />
        </div>
        <div className="order-1 sm:order-3 flex flex-1 px-2 sm:sticky top-4 self-start" />
      </div>

      <div className="flex items-center justify-center my-4">
        {isValidating ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, color: '#19c8b9', fontWeight: 600, fontSize: 13 }}>
            <ReloadIcon style={{ color: '#19c8b9', width: 16, height: 16 }} className="animate-spin" />
            <span>加载中...</span>
          </div>
        ) : dataList.length > 0 ? (
          size < pageTotal && (
            <Button
              type="primary"
              disabled={isLoading}
              onClick={() => setSize(size + 1)}
            >
              {t('Button.loadMore')}
            </Button>
          )
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, color: '#9f927d', padding: '32px 0' }}>
            <span style={{ fontSize: 32 }}>🏷</span>
            <p style={{ fontSize: 14, fontWeight: 600 }}>{t('Tips.noImg')}</p>
          </div>
        )}
      </div>
    </div>
  )
}
