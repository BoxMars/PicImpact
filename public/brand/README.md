# 大福映画 Felina Gallery · Logo

**logo 直接使用站点既有的 icon**，不再自己画。

## 来源
| 文件 | 说明 |
|---|---|
| `felina-logo-icon.png` | 复制自 `public/maskable-icon.png`（750×750，四周透明，PWA maskable 版） |
| `felina-logo-banner.svg` / `.png` | 该图标 + 「大福映画 / Felina Gallery」文字，2048×768 |

站点原有的图标资源（均在 `public/`）：

| 文件 | 实际尺寸 | 特征 |
|---|---|---|
| `favicon.svg` | 134×134 | 内嵌 base64 PNG（原作者文件名为「相机练习.png」） |
| `favicon.ico` | — | 浏览器标签页 |
| `apple-touch-icon.png` | **750×750** | 满幅，无透明 |
| `maskable-icon.png` | **750×750** | 内容 618×618，四周透明（与 `icons/icon-512x512.png` 同一文件） |
| `icons/icon-192x192.png`、`icon-512x512.png` | 750×750 | 与 maskable 同文件 |

> 注：`manifest.json` 里声明的尺寸（192/512）与文件实际尺寸（750）**不一致**，属既有问题，
> 未在本轮改动。

## 为什么用带透明的那一版
logo 要能放在任意背景上，所以选了四周透明的 `maskable-icon.png`，
而不是满幅无透明的 `apple-touch-icon.png`。若需要满幅版本，用它替换即可。

## 文字配色
- 中文标题 `#725D42`、英文 `#19C8B9`、下划线 `#C4B89E` —— 全部取自 ACNH 设计系统，
  与 App / 网页一致。

## 之前那版手绘稿
曾按「美短虎斑」手绘过一版（银灰毛 + 虎斑纹 + 额头 M + 绿眼），
用户认为不好看，已废弃删除。**根本原因：作者没有视觉能力**，
无法判断画得好不好看；毛色也是从像素统计推断的（暗调暖光把银灰照成米黄，推断错了）。
