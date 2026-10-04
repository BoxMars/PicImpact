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
