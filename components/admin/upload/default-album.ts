import type { AlbumType } from '~/types'

const UPLOAD_DEFAULT_ALBUM_STORAGE_KEY = 'picimpact-admin-upload-default-album'

export function resolveDefaultAlbum(albums: AlbumType[], currentAlbum: string): string {
  if (!albums || albums.length === 0) {
    return ''
  }

  const hasCurrentAlbum = albums.some(item => item.album_value === currentAlbum)
  if (currentAlbum && hasCurrentAlbum) {
    return currentAlbum
  }

  if (typeof window !== 'undefined') {
    const storedAlbum = window.localStorage.getItem(UPLOAD_DEFAULT_ALBUM_STORAGE_KEY) || ''
    const hasStoredAlbum = albums.some(item => item.album_value === storedAlbum)
    if (storedAlbum && hasStoredAlbum) {
      return storedAlbum
    }
  }

  return albums[0].album_value
}

export function persistDefaultAlbum(album: string) {
  if (typeof window === 'undefined') {
    return
  }
  window.localStorage.setItem(UPLOAD_DEFAULT_ALBUM_STORAGE_KEY, album)
}
