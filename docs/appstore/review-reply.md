以下内容可直接粘贴到 App Store Connect 的回复框与 Notes 字段
（本文件为纯文本，不含表格与 Markdown 符号；本行及文末「操作说明」一节不要粘贴）


1. Screen recording

A screen recording captured on a physical device (iPhone, latest iOS) is attached to this message.
It begins with launching the app and shows the typical user flow: the gallery and its scrolling,
opening a photo, the full EXIF capture parameters, tone analysis and the colour histogram, saving
the photo to the system Photos library including the permission dialog, the system share sheet,
pull to refresh, loading the next page, and the iPad layout in both orientations.

The app has no account registration, no login and no account deletion, no user generated content
and no reporting or blocking, and no paid content or in-app purchases, so none of those appear in
the recording.

中文

随本条消息附上一段在真机（iPhone，最新 iOS）上录制的屏幕录制。录制从启动 App 开始，展示了典型
使用流程：照片墙与滚动、点开照片、完整 EXIF 拍摄参数、影调分析与色彩直方图、保存到系统相册
（含权限弹窗）、系统分享面板、下拉刷新、加载下一页，以及 iPad 两种方向的布局。

本 App 没有账号注册、登录与账号删除，没有用户生成内容与举报屏蔽，也没有付费内容或内购，
因此录屏中不会出现这些。


2. Purpose and target audience

Felina Gallery (Da Fu Ying Hua) is a native iOS client for a personal photo album. The album
belongs to the developer himself and contains his own photographs, mostly of his cat named
"Daifuku" and his family.

Problem it solves: viewing a photo library on a phone through a website is slow and clunky. Every
image has to be fetched over the network, and none of the photographic metadata is presented in a
readable way. This app is a purpose-built viewer: it caches content locally so the gallery appears
instantly, presents full EXIF capture data (camera, lens, focal length, aperture, shutter, ISO),
computes tone analysis and a colour histogram on device, shows a map of where each photo was taken,
and lets the user save any photo to their own Photos library.

Target audience: the developer's family and friends, plus anyone who enjoys photography and likes
looking through a carefully presented album. There is no account system and no user generated
content. The album is read-only and all content is uploaded by the developer alone.

Native value, not a website wrapper: offline first-launch content, on-device image analysis, native
Photos integration, native share sheet, Dynamic Type and VoiceOver support, and an interface
adapted per device and orientation.

中文

大福映画（Felina Gallery）是一个个人相册的原生 iOS 客户端。相册属于开发者本人，内容是他自己
拍的照片，主要是他的猫「大福」与家人的日常。

解决的问题：用手机浏览器看相册很慢也很难看，每张图都要走网络，拍摄信息更是没法舒服地阅读。
这个 App 是一个专门做的浏览端：内容缓存在本地所以一打开就有，完整呈现 EXIF 拍摄参数，
在设备本地计算影调分析与色彩直方图，显示拍摄地点地图，并支持把照片保存到系统相册。

目标用户：开发者的家人朋友，以及喜欢摄影、愿意慢慢翻看一本相册的人。没有账号体系，也没有
用户投稿。相册是只读的，全部内容由开发者本人上传。

原生价值，不是网页套壳：首次启动即可离线看到内容、端上图像分析、系统相册与分享集成、
支持动态字体与旁白，以及按设备与方向分别适配的界面。


3. Instructions for setting up and accessing the main features

No setup, no login, no credentials, and no sample files are required. The app has no account system
at all.

1) Launch the app. The gallery loads immediately, because content is bundled and cached locally, so
   it works even with no network on the first launch.
2) Scroll the gallery. Pull down to refresh. Scroll to the bottom to load the next page.
3) Tap any photo to open the detail view: full image, capture parameters (EXIF), tone analysis,
   colour histogram, tags, and a map of the shooting location.
4) On the detail view, tap Save to write the photo into the system Photos library. This is the only
   system permission the app requests, and it is write-only: the app cannot read the user's photo
   library.
5) Tap Share to open the system share sheet.

中文

无需任何配置、登录、凭据或示例文件，本 App 完全没有账号体系。

1) 启动即见相册。内容已随安装包预置并做本地缓存，所以首次启动、不联网也能看到。
2) 上下滚动浏览。下拉刷新。滚到底自动加载下一页。
3) 点任意照片进入详情：大图、拍摄参数（EXIF）、影调分析、色彩直方图、标签、拍摄地点地图。
4) 详情页点「保存」写入系统相册。这是唯一的系统权限，且只写不读，App 无法查看用户相册里的
   任何内容。
5) 点「分享」唤起系统分享面板。


4. External services, tools, or platforms

The app talks to exactly two domains, both owned and operated by the developer.

  felina.boxz.dev        The website and the public API. Hosted on Vercel, behind Cloudflare
                         (CDN and DNS). Serves gallery metadata and resized preview images.
  felina-asset.boxz.dev  Photo storage and delivery, served through Cloudflare.

Behind the API there is a managed PostgreSQL database hosted on Supabase. The app never connects to
the database directly. It only calls the public HTTPS API, which reads the database server side.

The app itself contains no analytics, no crash reporting, no advertising, no authentication, no
payment and no AI services. Image analysis (tone analysis and histogram) is computed on device.
There are no in-app purchases.

中文

App 只与两个域名通信，两者都由开发者本人拥有和运营。

  felina.boxz.dev        站点与公开 API。托管在 Vercel，前面是 Cloudflare（CDN 与 DNS）。
                         提供画廊元数据与缩放后的预览图。
  felina-asset.boxz.dev  照片存储与分发，经 Cloudflare 提供。

API 背后是托管在 Supabase 上的 PostgreSQL 数据库。App 从不直连数据库，只调用公开 HTTPS API，
由服务端读取数据库。

App 内不含任何统计、崩溃上报、广告、认证、支付或 AI 服务。影调分析与直方图在设备本地计算。
没有内购。


5. Regional differences

There are no regional differences. The app behaves identically in every region and every App Store
storefront: the same content and the same features are available everywhere, with no geo
restrictions and no region-specific pricing or content. The photos were all taken in China and the
photo captions are written in Chinese, but the app's functionality, navigation and feature set do
not vary by region.

中文

没有任何地区差异。在所有地区和所有 App Store 店面中，本 App 的行为完全一致：内容相同、功能相同，
没有地域限制，也没有地区定价或地区专属内容。照片均拍摄于中国、图注文字为中文，
但 App 的功能、交互与能力不随地区变化。


6. Regulated industry or protected third-party material

Neither applies. The app does not operate in a regulated industry (no finance, health, gambling,
alcohol, cannabis, firearms or crypto functionality). It contains no third-party protected
material: every photograph, caption and design asset was created by the developer, who is the sole
copyright holder. The app contains no third-party trademarks and no licensed media, so no
authorisation documents are required.

中文

两项均不适用。本 App 不涉及受监管行业（无金融、医疗、赌博、酒精、大麻、枪械或加密货币功能），
也不含任何第三方受保护素材。全部照片、图注与设计稿均由开发者本人创作，版权归开发者所有。
App 内没有第三方商标或许可媒体，因此无需提供授权文件。


Appendix: notes on the Prevent Common Issues list

Guideline 2.1, bugs and crashes: the build was tested on physical devices, iPhone and iPad, on the
latest OS before submission.

Guideline 2.1, accessing the app: the app has no account-based features, so no demo credentials are
needed. There is no login screen.

Guideline 2.3.3, screenshots: all screenshots show the actual app in use, the photo gallery itself,
not title art, a login page or a splash screen.

Guideline 3.1.1, in-app purchase: the app has no in-app purchases and no paid content. All content
is free.

Guideline 3.2, other business models: this is a personal photo album app for the developer and his
family, not an app for a business, an organisation or its employees.

中文

2.1 崩溃与缺陷：提交前已在真机（iPhone 与 iPad）和最新系统上测试。

2.1 访问 App：没有账号类功能，因此无需演示账号，也没有登录页。

2.3.3 截屏：所有截屏都是 App 的实际使用画面（相册本身），不是标题图、登录页或启动页。

3.1.1 内购：没有内购，也没有付费内容，全部内容免费。

3.2 其他商业模式：这是开发者本人与家人使用的个人相册 App，不是面向企业、组织或员工的 App。

以上可粘贴内容结束。下面是你自己的操作说明，不要粘贴给审核员。


操作说明（不要粘贴）
--------------------

驳回原因是「开发者账号审核历史有限」，属于新账号的常规补充信息要求，不是 App 本身有问题。

第 1 项需要你本人在真机上录一段屏。Apple 明确要求 physical device（真机）与最新系统，
不要用模拟器。用系统自带的「屏幕录制」按下面顺序拍，约 60 到 90 秒：

1) 点图标启动 App。录制必须从启动开始。
2) 首页上下滚动，展示照片墙、顶部标题与张数。
3) 点开一张照片进入详情页，展示大图与拍摄参数（相机、镜头、焦距、光圈、曝光时间、感光度）。
4) 在详情页继续下滑，展示影调分析与色彩直方图。
5) 点「保存」，出现「添加到相册」权限弹窗，允许，然后到系统「照片」里确认已保存。
6) 点「分享」，出现系统分享面板。
7) 返回首页，下拉刷新，再滚到底展示自动加载下一页。
8) 如果是 iPad，旋转设备展示横竖屏自适应。

粘去哪里：App Store Connect 的回复框，以及「App 审核信息 → Notes」字段（Apple 要求两处都写）。

关于「双栏」这类说法：本文件里没有需要你判断的术语，照抄即可。
