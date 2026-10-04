# 大福映画 Felina Gallery · Logo

**logo 就是站点线上真正在用的那个图标**，不自己画。

## 来源（这是我第一版找错的地方）

线上 HTML 里是这样引用的：

```html
<link rel="apple-touch-icon" href="/apple-touch-icon.png"/>
<link rel="icon" href="https://felina-asset.boxz.dev/assert/ICON-Felina.jpg"/>
```

即 favicon **不是** `public/` 下的静态文件，而是**配置项** `custom_favicon_url`
（API 里暴露为 `site.faviconUrl`），指向 R2 上的 `assert/ICON-Felina.jpg`。
来源见 `app/layout.tsx`：

```ts
icons: { icon: data?.find((i) => i.config_key === 'custom_favicon_url')?.config_value || './favicon.ico' }
```

我第一版只翻了 `public/`（`favicon.svg` / `apple-touch-icon.png` / `maskable-icon.png`），
**那是没被用到的默认文件**，所以找错了。

## 文件
| 文件 | 说明 |
|---|---|
| `felina-logo-icon.jpg` | 站点真实图标，640×640 JPEG（`ICON-Felina.jpg` 原样） |
| `felina-logo-banner.svg` / `.png` | 该图标 + 「大福映画 / Felina Gallery」，2048×768 |

图标内容（像素统计）：银灰 `#D8D8D8` + 暖褐 `#C0A890`/`#A89078` + 深色 `#181818`，
左下角橙色 `#F29866` —— 与「美短虎斑」一致。

## 备注
- 该图是 **JPEG（无 alpha 通道）**。这恰好符合 iOS AppIcon 的要求（AppIcon 不允许透明），
  可直接用来生成各尺寸 App 图标。
- `public/` 下静态文件的 `manifest.json` 声明尺寸（192/512）与实际（750×750）不一致，
  属既有问题，且这些文件线上并未被引用。

## 之前两版手绘稿
都废弃删除了。根本原因是**作者没有视觉能力**，无法判断画得好不好看；
第一版连毛色都推错了（用"中心区域主色"统计，被暗调暖光带偏，把银灰虎斑算成了奶油色）。

## 本轮一并修掉的两处

### 1. 网页：manifest 声明尺寸与实际文件不符
原 `manifest.json` 声明 `/apple-touch-icon.png` 为 192×192、`/maskable-icon.png` 为 512×512，
而两个文件实际都是 **750×750**；且 `public/icons/` 下的图标线上根本没被引用。
现在全部按声明尺寸重新生成，**并且统一换成真实图标**（原先用的是没有被引用的默认图，
与 favicon 显示的猫不一致）：

| 文件 | 尺寸 | 用途 |
|---|---|---|
| `icons/icon-192x192.png` | 192×192 | PWA `any` |
| `icons/icon-512x512.png` | 512×512 | PWA `any` |
| `maskable-icon.png` | 512×512 | PWA `maskable`（内容 410×410 居中，底色取自图标左上角 `#EEEEEE`） |
| `apple-touch-icon.png` | 180×180 | iOS 主屏（Apple 推荐尺寸） |

`manifest.json` 已重写为引用上述文件。已逐项机器核对「声明尺寸 == 文件实际尺寸」。

### 2. iOS：工程设了 AppIcon 名字，但资源目录根本不存在
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 一直设着，但 `ios/PicImpact/` 下
**没有 `.xcassets`**，所以 App 从来没有图标。

新增 `Resources/Assets.xcassets/AppIcon.appiconset/`（1024×1024，无 alpha —— AppIcon
不允许透明，JPEG 源恰好满足）。同时修了生成脚本 `scripts/ios-project.py` 的两个问题：

- `if p.is_file()` 会把 `.xcassets` 这类**目录**整个漏掉
- 资源文件类型被硬编码成 `text.json.xcstrings`，对资源目录是错的（actool 不处理）

已用 `assetutil` 核对编译产物：`Assets.car` 内含 **AppIcon 1024×1024**；
App 包里出现 `AppIcon60x60@2x.png`，其主色与源图一致 —— 确实是大福，不是空白图标。

**注意**：1024 图标是从 **640×640 的源图放大**来的（1.6×），会略软。
若有更大的原图，替换 `AppIcon.appiconset/icon-1024.png` 即可。
