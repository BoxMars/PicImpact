import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  EXIF_CAPTURE_TIME_SQL,
  HOME_IMAGE_SORTING_ORDER,
  IMAGE_SORT_ORDERS,
  IMAGE_SORT_VALUES,
  parseImageSort,
} from '~/server/lib/image-sort'

/**
 * 排序片段的单测。
 *
 * 这一层是纯字符串 + 纯函数，但它是**契约的一部分**：`sort` 参数的含义、
 * 以及「不传时行为必须与旧版逐字节相同」这条保证，全在这里钉住。
 */

test('parseImageSort：只认这四个值，其余一律回退（不报错）', () => {
  for (const value of IMAGE_SORT_VALUES) {
    assert.equal(parseImageSort(value), value)
  }

  assert.equal(parseImageSort(undefined), undefined)
  assert.equal(parseImageSort(null), undefined)
  assert.equal(parseImageSort(''), undefined)
  assert.equal(parseImageSort('UPLOADED_DESC'), undefined, '大小写敏感，不做模糊匹配')
  assert.equal(parseImageSort('uploaded'), undefined)
  assert.equal(parseImageSort('uploaded_desc; DROP TABLE images'), undefined)
})

test('parseImageSort：原型链上的键名不能当合法值（用 in 判断就漏了）', () => {
  // 这几个用 `value in IMAGE_SORT_ORDERS` 会返回 true —— 一旦被当成合法 sort，
  // 后面就会拿 `toString` 这个函数去拼 SQL 片段。必须用 hasOwnProperty。
  for (const evil of ['__proto__', 'constructor', 'toString', 'hasOwnProperty', 'valueOf']) {
    assert.equal(parseImageSort(evil), undefined, `${evil} 不该被当成合法排序`)
  }
})

test('不传 sort 时的行为必须与旧版逐字节相同：taken_desc 就是「旧默认 + 全序兜底」', () => {
  assert.equal(
    IMAGE_SORT_ORDERS.taken_desc,
    `${HOME_IMAGE_SORTING_ORDER}, image.id DESC`,
    '拍摄时间从新到旧 = 首页原来的默认排序，只多了一个 id 兜底键'
  )
})

test('四条排序都以 image.id 收尾（否则 OFFSET 分页会重复/漏图）', () => {
  for (const [name, sql] of Object.entries(IMAGE_SORT_ORDERS)) {
    assert.match(sql, /image\.id (DESC|ASC)$/, `${name} 缺全序兜底键`)
  }
})

test('上传时间与拍摄时间是两回事：uploaded_* 不许出现 EXIF 表达式', () => {
  assert.equal(IMAGE_SORT_ORDERS.uploaded_desc.includes('exif'), false)
  assert.equal(IMAGE_SORT_ORDERS.uploaded_asc.includes('exif'), false)

  assert.ok(IMAGE_SORT_ORDERS.uploaded_desc.startsWith('image.created_at DESC'))
  assert.ok(IMAGE_SORT_ORDERS.uploaded_asc.startsWith('image.created_at ASC'))

  // 拍摄时间的两条必须真的用 EXIF 表达式（含取不到时回落 1970 的兜底）
  assert.ok(IMAGE_SORT_ORDERS.taken_desc.includes(EXIF_CAPTURE_TIME_SQL))
  assert.ok(IMAGE_SORT_ORDERS.taken_asc.includes(EXIF_CAPTURE_TIME_SQL))
  assert.ok(EXIF_CAPTURE_TIME_SQL.includes('\'1970-01-01 00:00:00\''))
})

test('IMAGE_SORT_VALUES 与 IMAGE_SORT_ORDERS 的键一致（文档/校验都靠它）', () => {
  assert.deepEqual([...IMAGE_SORT_VALUES].sort(), Object.keys(IMAGE_SORT_ORDERS).sort())
  assert.equal(IMAGE_SORT_VALUES.length, 4)
})
