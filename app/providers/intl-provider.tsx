'use client'

import { NextIntlClientProvider } from 'next-intl'

import defaultMessages from '~/messages/zh.json'
import { defaultLocale } from '~/i18n'

/**
 * 公开页使用的 intl provider。
 *
 * **必须放在客户端模块里导入 `NextIntlClientProvider`** —— 这是让公开页可静态化的关键。
 *
 * 原因（读 next-intl 4.8.3 源码确认）：从 `next-intl` 的**服务端**入口导入时，它解析到
 * `react-server/NextIntlClientProviderServer.js`，而那个实现是：
 *
 *   formats={formats === undefined ? await getFormats() : formats}
 *   now={now === undefined ? await getConfigNow() : now}
 *   locale={locale ?? await getLocale()}
 *   messages={messages === undefined ? await getMessages() : messages}
 *   timeZone={timeZone ?? await getTimeZone()}
 *
 * 也就是说**即使把 locale / messages / timeZone 都传全**，只要 `formats` 与 `now` 没传，
 * 它仍会 await getFormats() / getConfigNow()，从而走我们的 getRequestConfig
 * （i18n.ts → lib/utils/locale.ts 的 cookies()），把**整棵路由树**变成动态渲染 ——
 * 实测后果是生产环境 HTML 永远 `x-vercel-cache: MISS`。
 *
 * 客户端入口（index.react-client.js）则解析到 `shared/NextIntlClientProvider.js`，
 * 是个纯取 props、没有任何 await 的 `'use client'` 组件。
 *
 * 另外：语言包在客户端模块里静态导入，会被打进**可长期缓存**的 JS chunk，
 * 而不是每次请求都随不可缓存的 HTML 下发。`messages/zh.json` 仅 15.8 KB。
 *
 * `useNow` / `useFormatter` / `useTimeZone` 全站未被使用（已核对），
 * 因此不传 `now` / `formats`，也就不存在「服务端与客户端时间不同导致水合不一致」的问题。
 */
export function IntlProvider({ children }: { children: React.ReactNode }) {
  return (
    <NextIntlClientProvider
      locale={defaultLocale}
      messages={defaultMessages}
      timeZone="Asia/Shanghai"
    >
      {children}
    </NextIntlClientProvider>
  )
}
