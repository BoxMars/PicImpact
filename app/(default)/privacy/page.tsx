import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: '隐私政策 · 大福映画',
  description: '大福映画不采集任何个人数据。',
}

/**
 * 隐私政策页。
 *
 * ⚠️ 内容必须与 App 的**实际行为**一致（App Store 审核会核对）：
 * - 工程里没有任何分析 / 崩溃上报 / 广告 SDK
 * - 唯一的系统权限是「添加到相册」（NSPhotoLibraryAddUsageDescription，**只写不读**）
 * - 不请求定位权限，也不读取用户位置
 * - App 只访问自家的 felina.boxz.dev / felina-asset.boxz.dev
 * 改动 App 行为时，这一页要同步改。
 */
export default function PrivacyPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-16 leading-relaxed" style={{ color: '#725d42' }}>
      <h1 className="mb-2 text-3xl font-bold">隐私政策</h1>
      <p className="mb-10 text-sm" style={{ color: '#9f927d' }}>生效日期：2026 年 10 月 4 日</p>

      <p className="mb-8 text-lg font-medium">
        一句话总结：<strong>大福映画不采集你的任何个人数据。</strong>
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">这个 App 是什么</h2>
      <p className="mb-4">
        大福映画（Felina Gallery）是我们家的相册客户端。它展示的照片全部由开发者本人拍摄并发布在
        自建站点 felina.boxz.dev 上，内容是一只名叫「大福」的猫与家人的日常。App 不提供账号体系，
        也不接受任何用户投稿。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">我们收集哪些数据</h2>
      <p className="mb-4"><strong>没有。</strong>具体来说：</p>
      <ul className="mb-4 list-disc space-y-2 pl-6">
        <li>不需要注册，也没有账号，因此不收集邮箱、手机号、姓名等任何身份信息</li>
        <li>不含任何数据分析、崩溃上报或广告 SDK，因此不收集设备标识、使用行为或崩溃日志</li>
        <li>不请求定位权限，也不读取你的位置</li>
        <li>不向任何第三方共享或出售数据（因为没有可共享的数据）</li>
      </ul>

      <h2 className="mt-10 mb-3 text-xl font-bold">关于相册权限</h2>
      <p className="mb-4">
        App 只有在<strong>你主动点击「保存」</strong>时，才会请求「添加到相册」权限，用于把当前这张照片
        存进你的系统相册。这个权限是<strong>只写不读</strong>的 —— App 无法查看、读取或上传你相册里的
        任何内容。你可以随时在「设置 → 隐私与安全性 → 照片」中收回该权限。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">网络请求</h2>
      <p className="mb-4">
        App 仅访问以下两个由开发者控制的域名，用于获取照片与其拍摄参数（EXIF）：
        felina.boxz.dev（内容接口）与 felina-asset.boxz.dev（图片资源）。
        除此之外不会向任何其他服务器发送请求。这些请求不携带任何可识别你身份的信息。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">照片中的位置信息</h2>
      <p className="mb-4">
        部分照片的 EXIF 中带有拍摄时的经纬度。这些坐标是<strong>拍摄设备写入照片本身的</strong>，
        由开发者在发布时一并提供，与你（浏览者）的位置无关。App 不会读取你的定位。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">儿童隐私</h2>
      <p className="mb-4">
        由于不收集任何数据，本 App 同样不会收集儿童的个人信息。年龄分级为 4+。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">数据的保留与删除</h2>
      <p className="mb-4">
        因为不收集数据，也就没有需要保留或删除的数据。如果你希望卸载 App，直接删除即可，
        不会遗留任何属于你的信息。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">政策变更</h2>
      <p className="mb-4">
        若将来功能变化导致本政策需要修改，我们会更新本页并修改顶部的「生效日期」。
      </p>

      <h2 className="mt-10 mb-3 text-xl font-bold">联系我们</h2>
      <p className="mb-4">
        对本政策有任何疑问，可通过<strong>me@boxz.dev</strong>联系我们。
      </p>

      <p className="mt-12 text-sm" style={{ color: '#9f927d' }}>
        本页对应 App：大福映画（Bundle ID: dev.boxz.felina）
      </p>
    </main>
  )
}
