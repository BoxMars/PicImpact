import 'server-only'
import { Hono } from 'hono'
import settings from '~/hono/settings'
import file from '~/hono/file'
import images from '~/hono/images'
import albums from '~/hono/albums'
import admin from '~/hono/admin'
import openList from '~/hono/storage/open-list.ts'
import { HTTPException } from 'hono/http-exception'

const route = new Hono()

route.onError((err, c) => {
  if (err instanceof HTTPException) {
    console.error(err)
    return err.getResponse()
  }
})

route.route('/settings', settings)
route.route('/file', file)
route.route('/images', images)
route.route('/albums', albums)
// 管理端接口（App 的上传签发 / 登记 / 列表 / 删除）。
// 挂在既有的 /api/v1 前缀下，就原样沿用了 proxy.ts 对 /api/v1 的会话门禁；
// 路由内部还会用 auth.api.getSession() 再做一次**真正的**校验（那道门禁只判断 cookie 在不在）。
route.route('/admin', admin)
route.route('/storage/open-list', openList)

export default route