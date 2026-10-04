import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: '使用条款 · 大福映画',
  description: '大福映画的使用条款。',
}

export default function TermsPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-16 leading-relaxed" style={{ color: '#725d42' }}>
      <h1 className="mb-2 text-3xl font-bold">使用条款</h1>
      <p className="mb-10 text-sm" style={{ color: '#9f927d' }}>生效日期：2026 年 10 月 4 日</p>

      <h2 className="mt-10 mb-3 text-xl font-bold">一、这是什么</h2>
      <p className="mb-4">
        大福映画（Felina Gallery）是开发者自用的家庭相册应用，内容为开发者本人拍摄的家庭照片，
        仅用于浏览与欣赏。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">二、内容版权</h2>
      <p className="mb-4">
        本应用及站点中的全部照片、文字与界面设计，版权归开发者所有。未经许可，
        请勿转载、二次发布或用于任何商业用途。你可以把照片保存到自己的设备用于个人欣赏。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">三、使用许可</h2>
      <p className="mb-4">
        我们授予你一项个人的、非独占的、不可转让的许可，用于在你自己拥有的设备上安装并使用本应用。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">四、免责</h2>
      <p className="mb-4">
        本应用按「现状」提供。我们会尽力保证服务可用，但不对因网络、设备或服务中断造成的
        不便承担责任。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">五、条款变更</h2>
      <p className="mb-4">
        若条款发生变更，我们会更新本页并修改顶部的「生效日期」。继续使用即表示接受更新后的条款。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">六、联系我们</h2>
      <p className="mb-4">任何疑问可通过 me@boxz.dev 联系我们。</p>
    </main>
  )
}
