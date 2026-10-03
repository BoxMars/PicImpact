'use client'

import { useMemo, useState, useRef, useCallback, memo } from 'react'
import type { HandleProps, ImageHandleProps } from '~/types/props.ts'
import useSWRInfinite from 'swr/infinite'
import { useSwrHydrated } from '~/hooks/use-swr-hydrated.ts'
import { DraggableCardBody, DraggableCardContainer } from '~/components/ui/origin/draggable-card.tsx'
import type { ImageType } from '~/types'
import Image from 'next/image'
import { Skeleton } from '~/components/ui/skeleton'
import { useBlurImageDataUrl } from '~/hooks/use-blurhash'
import { cn } from '~/lib/utils'

/**
 * 拍立得照片卡片组件
 * @param props - 包含图片数据、位置样式和点击处理函数
 */
/**
 * 把任意字符串映射到 [0, 1) 的确定性数值（FNV-1a + salt）。
 * 用于给宝丽来卡片生成"看起来随机、但每次渲染都一致"的散落位置。
 */
function hashToUnit(id: string, salt: number): number {
  let h = (2166136261 ^ salt) >>> 0
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i)
    h = Math.imul(h, 16777619) >>> 0
  }
  return (h % 100000) / 100000
}

// 6 种相纸规格（单位: mm）。提到模块级 —— 原先定义在组件体内，每次渲染都重建这个数组。
const POLAROID_STYLES = [
  { name: '富士MINI', cardW: 54, cardH: 86, imgW: 46, imgH: 62 },
  { name: '富士WIDE', cardW: 108, cardH: 86, imgW: 99, imgH: 62 },
  { name: '富士SQ', cardW: 72, cardH: 86, imgW: 62, imgH: 62 },
  { name: '宝丽来GO', cardW: 53.9, cardH: 66.6, imgW: 47, imgH: 46 },
  { name: '宝丽来宽幅', cardW: 103, cardH: 102, imgW: 92, imgH: 73 },
  { name: '宝丽来标准', cardW: 88.5, cardH: 107.5, imgW: 78.9, imgH: 76.8 },
]

const PolaroidCard = memo(function PolaroidCard({
  item,
  style,
  onMouseDown,
  zIndex,
}: {
  item: ImageType
  style: React.CSSProperties
  onMouseDown: (id: string) => void
  zIndex: number
}) {
  const [isLoading, setIsLoading] = useState(true)
  const [imgSrc, setImgSrc] = useState(item.preview_url)
  const blurDataUrl = useBlurImageDataUrl(item.blurhash)

  // 根据图片比例自动选择最合适的相纸。
  //
  // ⚠️ 这个 useMemo 必须位于下面那个 early return **之前**：原先它写在
  // `if (!item.width ...) return null` 之后，属于条件调用 Hook —— 一旦某张卡片的
  // 宽高从中途从 0 变为有效（或反之），React 会抛
  // "Rendered fewer hooks than expected"，整页崩溃。
  const selectedStyle = useMemo(() => {
    if (!item.width || !item.height || item.width <= 0 || item.height <= 0) {
      return POLAROID_STYLES[POLAROID_STYLES.length - 1]
    }
    const imgRatio = item.width / item.height
    return POLAROID_STYLES.reduce((prev, curr) => {
      const currRatio = curr.imgW / curr.imgH
      const prevRatio = prev.imgW / prev.imgH
      return Math.abs(imgRatio - currRatio) < Math.abs(imgRatio - prevRatio) ? curr : prev
    })
  }, [item.width, item.height])

  // 如果缺少宽高数据，则跳过渲染以规避报错（此时上面的 Hook 已经无条件执行过）
  if (!item.width || !item.height || item.width <= 0 || item.height <= 0) {
    return null
  }

  // 物理尺寸转像素比例 (1mm = 3.8px)
  const scale = 3.8
  const cardWidth = selectedStyle.cardW * scale
  const cardHeight = selectedStyle.cardH * scale
  const imgWidth = selectedStyle.imgW * scale
  const imgHeight = selectedStyle.imgH * scale

  // 计算边距 (通常左右居中，顶部边距等于侧边，剩余给底部)
  const paddingSide = (cardWidth - imgWidth) / 2
  const paddingTop = paddingSide
  const paddingBottom = cardHeight - imgHeight - paddingTop

  return (
    <DraggableCardBody
      className="absolute flex flex-col p-0 min-h-0 h-auto rounded-sm"
      style={{
        ...style,
        zIndex,
        width: `${cardWidth}px`,
        height: `${cardHeight}px`,
        padding: `${paddingTop}px ${paddingSide}px ${paddingBottom}px ${paddingSide}px`,
        background: 'rgb(247, 243, 223)',
        border: '2px solid #c4b89e',
        boxShadow: '0 4px 0 0 #bdaea0, 0 8px 24px rgba(121,79,39,0.15)',
      }}
      onMouseDown={() => onMouseDown(item.id)}
    >
      <div
        className="relative overflow-hidden shrink-0 w-full h-full"
        style={{ background: '#e8dcc8' }}
      >
        {isLoading && (
          <Skeleton className="absolute inset-0 z-20 rounded-none" />
        )}
        <Image
          src={imgSrc}
          alt={item.title}
          width={Math.round(imgWidth)}
          height={Math.round(imgHeight)}
          className={cn(
            'pointer-events-none relative z-10 h-full w-full object-cover transition-opacity duration-500',
            isLoading ? 'opacity-0' : 'opacity-100'
          )}
          placeholder="blur"
          blurDataURL={blurDataUrl}
          onLoad={() => setIsLoading(false)}
          onError={() => {
            if (imgSrc !== item.url) {
              setImgSrc(item.url)
            }
          }}
          // 卡片宽度是固定的 px（175~376px），原来的 `33vw`（在 2560 宽屏上 = 845px）
          // 与实际显示尺寸严重不符，会拉到过大的候选图。
          sizes="(max-width: 768px) 90vw, 380px"
          priority={false}
        />
      </div>
      <div
        className="absolute bottom-0 left-0 right-0 flex items-center justify-center px-2 overflow-hidden"
        style={{ height: `${paddingBottom}px` }}
      >
        <h3
          style={{
            width: '100%',
            textAlign: 'center',
            fontSize: 12,
            fontWeight: 700,
            color: '#9f927d',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            letterSpacing: '0.02em',
            fontFamily: 'Nunito, sans-serif',
          }}
        >
          {item.title}
        </h3>
      </div>
    </DraggableCardBody>
  )
})

/**
 * 拍立得画廊组件
 * @param props - 包含配置处理和图片加载处理
 */
export default function PolaroidGallery(props: Readonly<ImageHandleProps>) {
  const configProps: HandleProps = {
    handle: props.configHandle,
    args: 'system-config',
  }
  const { data: configData } = useSwrHydrated(configProps, props.initialConfigData)

  const customTitle = configData?.find((item: any) => item.config_key === 'custom_title')?.config_value.toString()

  const { data } = useSWRInfinite((index) => {
    return [`client-${props.args}-${index}-${props.album}`, index]
  },
    ([_, index]) => {
      return props.handle(index + 1, props.album)
    }, {
    revalidateOnFocus: false,
    revalidateIfStale: false,
    revalidateOnReconnect: false,
    fallbackData: props.initialImages ? [props.initialImages] : undefined,
  })

  const dataList = useMemo(() => data ? [].concat(...data) : [], [data])

  // 由图片 id 派生的**稳定**伪随机位置。
  //
  // 原先的位置用 `Math.random()` 在 render 期间求值并写进一个 ref：
  //   - 违反 React 的 purity 约定（渲染期间产生副作用 + 非确定性）；
  //   - 服务端渲染与水合会算出不同的位置，导致水合不一致与视觉跳动。
  // 改成 id 的哈希：同一张图永远得到同一个位置，追加数据时旧图位置也不变
  // （原先正是靠 ref 来保证这一点），于是那个 ref 不再需要。
  const currentPositions = useMemo(() => {
    const positions: Record<string, { top: string, left: string, rotate: string }> = {}
    for (const item of dataList as ImageType[]) {
      positions[item.id] = {
        top: `${Math.floor(hashToUnit(item.id, 1) * 40) + 10}%`, // 10% - 50%
        left: `${Math.floor(hashToUnit(item.id, 2) * 50) + 10}%`, // 10% - 60%
        rotate: `${Math.floor(hashToUnit(item.id, 3) * 20) - 10}deg`, // -10deg - 10deg
      }
    }
    return positions
  }, [dataList])

  const maxZIndexRef = useRef(10)
  const [cardZIndices, setCardZIndices] = useState<Record<string, number>>({})

  /**
   * 处理卡片点击，将其置于最顶层
   * @param id - 图片 ID
   */
  const handleCardClick = useCallback((id: string) => {
    maxZIndexRef.current += 1
    const newZIndex = maxZIndexRef.current
    setCardZIndices((prev) => ({
      ...prev,
      [id]: newZIndex,
    }))
  }, [])

  return (
    <DraggableCardContainer className="relative flex min-h-screen w-full items-center justify-center overflow-clip">
      <div
        className="absolute top-1/2 -translate-y-3/4 flex flex-col items-center gap-3 pointer-events-none"
        style={{ zIndex: 0 }}
      >
        <p
          className="mx-auto max-w-sm text-center text-2xl md:text-4xl"
          style={{
            fontWeight: 900,
            color: '#c4b89e',
            letterSpacing: '0.04em',
            fontFamily: 'Nunito, sans-serif',
          }}
        >
          {customTitle || '大福映画 Felina Gallery'}
        </p>
        <p style={{ color: '#d4c9b4', fontSize: 14, fontWeight: 600, letterSpacing: '0.06em' }}>
          🏝 拖动照片探索小岛
        </p>
      </div>
      {dataList?.map((item: ImageType) => (
        <PolaroidCard
          key={item.id}
          item={item}
          style={currentPositions[item.id]}
          zIndex={cardZIndices[item.id] || 1}
          onMouseDown={handleCardClick}
        />
      ))}
    </DraggableCardContainer>
  )
}
