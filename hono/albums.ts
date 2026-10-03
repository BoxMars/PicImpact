import 'server-only'
import { fetchAlbumsList } from '~/server/db/query/albums'
import { revalidateTag } from 'next/cache'
import { ALBUMS_TAG } from '~/server/db/query/albums'
import { deleteAlbum, insertAlbums, updateAlbum, updateAlbumShow } from '~/server/db/operate/albums'
import { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'

const app = new Hono()

/**
 * 失效相册缓存。包 try/catch：失效失败不应让管理端的写操作失败。
 */
function invalidateAlbums() {
  try {
    revalidateTag(ALBUMS_TAG)
  } catch (e) {
    console.warn('[cache] revalidateTag(albums) 失败：', e)
  }
}

app.get('/get', async (c) => {
  const data = await fetchAlbumsList()
  return c.json(data)
})

app.post('/add', async (c) => {
  const album = await c.req.json()
  if (album.album_value && album.album_value.charAt(0) !== '/') {
    throw new HTTPException(500, { message: 'The route must start with /' })
  }
  try {
    await insertAlbums(album)
    invalidateAlbums()
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.put('/update', async (c) => {
  const album = await c.req.json()
  if (album.album_value && album.album_value.charAt(0) !== '/') {
    throw new HTTPException(500, { message: 'The route must start with /' })
  }
  try {
    await updateAlbum(album)
    invalidateAlbums()
    return c.json({ code: 200, message: 'Success' })
  } catch (e) {
    throw new HTTPException(500, { message: 'Failed', cause: e })
  }
})

app.delete('/delete/:id', async (c) => {
  const { id } = c.req.param()
  const data = await deleteAlbum(id)
  invalidateAlbums()
  return c.json(data)
})

app.put('/update-show', async (c) => {
  const album = await c.req.json()
  const data = await updateAlbumShow(album.id, album.show)
  invalidateAlbums()
  return c.json(data)
})

export default app