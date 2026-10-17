import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  DEFAULT_PUSH_BODY_TEMPLATE,
  FALLBACK_TITLE,
  PUSH_TEMPLATE_PLACEHOLDERS,
  isValidPushTemplate,
  renderPushBody,
} from '~/server/lib/push-template'

/**
 * 通知正文模板（`configs.push_body_template`）。
 *
 * 这段逻辑的特点是「错了不会报错，只会发出奇怪的文字」，所以边界都钉住：
 * 占位符两种写法、缺值兜底、整句被替空、白名单长度。
 */

test('默认模板：标题套进「」', () => {
  assert.equal(renderPushBody(undefined, { title: '海边日落' }), '「海边日落」刚刚上传')
  assert.equal(renderPushBody('', { title: '海边日落' }), DEFAULT_PUSH_BODY_TEMPLATE.replace('{{title}}', '海边日落'))
})

test('两个占位符都能用，大小写与花括号内空格都容忍', () => {
  assert.equal(renderPushBody('{{album}} 上新：{{title}}', { title: 'X', album: '日常' }), '日常 上新：X')
  assert.equal(renderPushBody('{{ TITLE }} / {{ Album }}', { title: 'X', album: '日常' }), 'X / 日常')
})

test('没有标题：用文件名；连文件名都没有：写「一张新照片」', () => {
  assert.equal(renderPushBody('{{title}}', { title: null }), FALLBACK_TITLE)
  assert.equal(renderPushBody('新图：{{title}}', { title: '  ' }), `新图：${FALLBACK_TITLE}`)
})

test('整句被替空时回落到默认文案，绝不发空正文', () => {
  // 模板只有 {{album}}，但相册名缺失 → 渲染结果是空串
  const body = renderPushBody('{{album}}', { title: '海边日落', album: null })
  assert.equal(body, '「海边日落」刚刚上传')
  assert.ok(body.length > 0)
})

test('模板里没有占位符也照发（就是想固定一句话）', () => {
  assert.equal(renderPushBody('快来看新照片呀', { title: 'X' }), '快来看新照片呀')
})

test('校验：1–300 字，空/超长/控制字符拒绝', () => {
  assert.equal(isValidPushTemplate('「{{title}}」刚刚上传'), true)
  assert.equal(isValidPushTemplate('x'), true)
  assert.equal(isValidPushTemplate(''), false)
  assert.equal(isValidPushTemplate('   '), false)
  assert.equal(isValidPushTemplate('x'.repeat(301)), false)
  assert.equal(isValidPushTemplate('带\u0007控制字符'), false)
})

test('占位符清单与文档一致（后台界面直接展示这两个）', () => {
  assert.deepEqual([...PUSH_TEMPLATE_PLACEHOLDERS], ['{{title}}', '{{album}}'])
})
