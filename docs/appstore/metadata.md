# App Store Connect 填表内容

> 所有长度上限都用脚本校验过（见文末）。直接复制对应字段即可。

## 1. App 信息

| 字段 | 内容 | 上限 |
|---|---|---|
| **名称** | 大福映画 | 30 |
| **副标题** | 大福与家人的光影记录 | 30 |
| **Bundle ID** | dev.boxz.felina | — |
| **SKU** | FELINA-GALLERY-001（自定义，仅后台用，不可重复） | — |
| **主要语言** | 简体中文 | — |
| **版权** | © 2026 Felina | — |

**名称备选**（都在 30 以内）：
- `大福映画` — 与设备上显示名一致，最干净
- `大福映画 - 猫咪相册` — 带品类词，搜索时更容易被命中

## 2. 推广文本（可随时改，不需审核）

```
一只叫大福的猫，和爱它的人。
这里是我们家的照片本 —— 记录日常的光、影，和每个值得留下的瞬间。
```

## 3. 描述

```
大福映画是我们家的照片本。

一只叫大福的猫，和爱它的家人。这里收着我们拍下的日常：阳光下的酣睡、草地上
的漫步、偶尔的哈欠，以及那些说不清为什么但就是想留下来的瞬间。

【关于这个相册】
・照片按时间与画幅自然错落排布，像摊在桌上的实物相片
・每张照片都保留拍摄参数：机身、镜头、焦距、光圈、曝光时间、感光度
・自动生成影调分析与色彩直方图，方便看一张照片的明暗与色彩分布
・点开大图可保存到系统相册

【风格】
界面用纸卡与手账的质感来做：米白的纸、暖褐的字、圆润的描边，
以及一条随页面滑动的缎带标题。希望它看起来更像一本实体相册，而不是一个图片流。

【说明】
・内容来自我们自己的站点，不含任何用户投稿
・没有账号体系，无需登录
・不采集任何个人数据，详见隐私政策
```

**备选副标题**（若想更直白）：
- `我们家的照片本` 
- `和一只叫大福的猫` 

## 4. 关键词（逗号分隔，**不要加空格** —— 空格也算字符）

```
大福,猫咪,猫,相册,家庭,照片,画廊,摄影,记录,日常,Felina,cat,gallery,photo,album,EXIF
```

## 5. URL

| 字段 | 值 | 说明 |
|---|---|---|
| **支持 URL** | https://felina.boxz.dev | 必填，已确认可访问（HTTP 200） |
| **营销 URL** | https://felina.boxz.dev | 选填 |
| **隐私政策 URL** | https://felina.boxz.dev/privacy | **必填**，已确认可访问（HTTP 200） |

## 6. 分类与分级

| 字段 | 值 |
|---|---|
| **主要分类** | 摄影与录像（备选：杂志与报纸） |
| **次要分类** | 不填 |
| **年龄分级** | 4+ |

**分级问卷的答题要点**（若被问到）：
- 无用户生成内容、无用户间交流 ✓（内容是我们自己站点的照片）
- 无不受限的网页访问 ✓
- 无暴力/成人/赌博/药品等内容 ✓

> 注意：工程 `Info.plist` 里目前写的是 `public.app-category.magazines-and-newspapers`
> （杂志与报纸）。若要改成「摄影与录像」，告诉我改一处即可，保持两边一致。

## 7. 隐私标签（App 隐私）

**结论：Data Not Collected（不采集数据）**

依据（已核对代码）：
- 工程里没有任何分析 / 崩溃上报 / 广告 SDK（Firebase、Sentry、友盟、AppsFlyer… 均无）
- 唯一命中的 `umamiAnalytics` 只是 Web 端设置项在字符串表里的**词条**，App 未接入
- App 只向自家 API 读取相册数据，不发往任何第三方
- 唯一的系统权限是 **「添加到相册」**（保存图片用），属于功能权限，不构成数据采集

**追踪（Tracking）**：不涉及 —— 不需要 ATT 弹窗

## 8. App 审核备注（中英文各一份，直接都粘进去）

> App Store Connect 的 Notes 字段上限 4000 字符；两份合起来约 700，够用。
> 中英文都放，审核员（可能不是中文母语）能直接读英文那份。

### 中文

```
本 App 是一个家庭相册客户端，内容来自开发者自建站点 felina.boxz.dev 的公开相册
（照片是一只名叫「大福」的猫与家人的日常）。

・无需登录，也没有账号体系，打开即可看到全部内容
・底部/详情页的「保存」按钮会请求「添加到相册」权限（该权限只写不读，App 无法查看用户相册）
・内容全部由开发者本人上传，不含任何用户投稿或第三方内容
・如需查看内容来源，可直接访问 https://felina.boxz.dev
```

### English

```
This app is a family photo gallery client. All content comes from the developer's own public
album at felina.boxz.dev (photos of a cat named "Daifuku" and his family).

- No login and no account system: everything is visible as soon as the app opens.
- The "Save" button on the detail page requests the "Add to Photo Library" permission. This
  permission is write-only: the app cannot read or view anything in your photo library.
- All content is uploaded by the developer. There is no user-generated or third-party content.
- To see where the content comes from, visit https://felina.boxz.dev
```

## 9. 上传用的截图

| 文件 | 尺寸 | 对应槽位 |
|---|---|---|
| `iphone-65-gallery.png` | 1284×2778 | iPhone 6.5 吋 |
| `ipad-13-gallery.png` | 2048×2732 | iPad 13 吋 |

---

## 附：长度校验

由 `scripts/check-appstore-metadata.py` 校验，上限来自 App Store Connect：
