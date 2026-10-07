import 'server-only'
import { fetchConfigsByKeys } from '~/server/db/query/configs'

import { Hono } from 'hono'
import { requireSession } from '~/hono/require-session'
import type { Config } from '~/types'

const app = new Hono()

// 真正的会话校验（proxy.ts 那道门禁只判断 cookie 在不在，不能作为鉴权依据）
app.use('*', requireSession)

app.get('/info', async (c) => {
  const data = await fetchConfigsByKeys([
    'open_list_url',
    'open_list_token'
  ])
  return c.json(data)
})

app.get('/storages', async (c) => {
  const findConfig = await fetchConfigsByKeys([
    'open_list_url',
    'open_list_token'
  ])
  const openListToken = findConfig.find((item: Config) => item.config_key === 'open_list_token')?.config_value || ''
  const openListUrl = findConfig.find((item: Config) => item.config_key === 'open_list_url')?.config_value || ''

  const data = await fetch(`${openListUrl}/api/admin/storage/list`, {
    method: 'get',
    headers: {
      'Authorization': openListToken.toString(),
    },
  }).then(res => res.json())
  return c.json(data)
})

export default app