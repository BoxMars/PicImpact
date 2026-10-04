import 'server-only'

import { Hono } from 'hono'

import v1 from './v1'

/**
 * 公开 API（无需鉴权）的版本挂载点。
 *
 * 新增版本时在这里加一行 `app.route('/v2', v2)` —— **不要**修改或删除已有版本。
 * 旧版 App 无法被强制升级，删掉一个版本就等于让那部分用户直接不可用。
 * 下线流程见 docs/superpowers/api/public-api-v1.md。
 */
const app = new Hono()

app.route('/v1', v1)

export default app
