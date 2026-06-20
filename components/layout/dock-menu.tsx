'use client'

import { useRouter } from 'next-nprogress-bar'
import { useTranslations } from 'next-intl'
import { useEffect, useState } from 'react'
import { useButtonStore } from '~/app/providers/button-store-providers'
import Command from '~/components/layout/command'
import type { AlbumDataProps } from '~/types/props'
import type { AlbumType } from '~/types'
import { Button, Modal, Icon, Tooltip } from 'animal-island-ui'

export default function DockMenu(props: Readonly<AlbumDataProps>) {
  const router = useRouter()
  const t = useTranslations()
  const [isOpen, setIsOpen] = useState(false)
  const { setCommand } = useButtonStore((state) => state)

  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.key === 'k' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        setCommand(true)
      }
    }
    document.addEventListener('keydown', down)
    return () => document.removeEventListener('keydown', down)
  }, [setCommand])

  return (
    <>
      {/* Island-style floating dock */}
      <div
        style={{
          position: 'fixed',
          bottom: 'calc(16px + env(safe-area-inset-bottom, 0px))',
          left: '50%',
          transform: 'translateX(-50%)',
          zIndex: 50,
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          padding: '8px 16px',
          background: 'rgb(247, 243, 223)',
          border: '2.5px solid #c4b89e',
          borderRadius: 50,
          boxShadow: '0 6px 0 0 #bdaea0, 0 10px 30px rgba(121,79,39,0.15)',
        }}
      >
        <DockButton
          label={t('Link.home')}
          onClick={() => router.push('/')}
          color="#82d5bb"
        >
          <Icon name="icon-map" size={22} />
        </DockButton>

        <div style={{ width: 1, height: 28, background: '#c4b89e', margin: '0 4px' }} />

        <DockButton
          label={t('Words.album')}
          onClick={() => setIsOpen(true)}
          color="#f8a6b2"
        >
          <Icon name="icon-critterpedia" size={22} />
        </DockButton>

        <div style={{ width: 1, height: 28, background: '#c4b89e', margin: '0 4px' }} />

        <DockButton
          label={t('Link.settings')}
          onClick={() => setCommand(true)}
          color="#f7cd67"
        >
          <Icon name="icon-variant" size={22} />
        </DockButton>
      </div>

      <Command {...props} />

      {/* Island-style album selection modal */}
      <Modal
        open={isOpen}
        title={t('Words.album')}
        onClose={() => setIsOpen(false)}
        footer={null}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 8 }}>
          {Array.isArray(props.data) && props.data.length > 0 ? (
            props.data.map((album: AlbumType) => (
              <Button
                key={album.id}
                type="default"
                block
                onClick={() => {
                  router.push(album.album_value)
                  setIsOpen(false)
                }}
              >
                <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <Icon name="icon-critterpedia" size={16} />
                  {album.name}
                </span>
              </Button>
            ))
          ) : (
            <p style={{ textAlign: 'center', color: '#9f927d', padding: '16px 0' }}>
              暂无相册
            </p>
          )}
        </div>
      </Modal>
    </>
  )
}

function DockButton({
  children,
  label,
  onClick,
  color,
}: {
  children: React.ReactNode
  label: string
  onClick: () => void
  color: string
}) {
  const [hovered, setHovered] = useState(false)

  return (
    <Tooltip title={label} variant="island" placement="top">
      <button
        aria-label={label}
        onClick={onClick}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: 44,
          height: 44,
          borderRadius: 50,
          border: `2px solid ${hovered ? '#19c8b9' : '#c4b89e'}`,
          background: hovered ? color : 'rgb(247, 243, 223)',
          color: hovered ? '#fff' : '#725d42',
          cursor: 'pointer',
          transition: 'all 0.2s cubic-bezier(0.4, 0, 0.2, 1)',
          transform: hovered ? 'translateY(-3px) scale(1.1)' : 'translateY(0) scale(1)',
          boxShadow: hovered ? `0 4px 0 0 ${color}99, 0 6px 16px ${color}44` : 'none',
          outline: 'none',
        }}
      >
        {children}
      </button>
    </Tooltip>
  )
}
