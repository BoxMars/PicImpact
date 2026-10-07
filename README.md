<h1 align="center">
  <img width="28" src="./public/maskable-icon.png">
  Felina · 大福映画
</h1>

<p align="center">
  个人摄影作品站（Web）+ 配套 iOS App —— 同一批照片，两个入口。
</p>

## 这是什么

一个自用的摄影作品展示站：网页端给访客看，iOS App 给自己和朋友看。
所有照片存在自己的对象存储里，元数据在一台自己控制的 PostgreSQL 上。

线上：`felina.boxz.dev` ｜ 图床：`felina-asset.boxz.dev`（Cloudflare R2 + 自定义域）
iOS：App Store 上的「大福映画」（Lifestyle，免费）

## 功能

**网页端**

- 瀑布流相册，图片直连资产域（走 Cloudflare 边缘缓存，不经过函数）
- 详情页：原图查看 + 拍摄参数 / 设备信息 / 直方图，支持左右切换
- 相册、标签、地图（按 EXIF 经纬度）三种浏览方式
- EXIF 信息完整展示，支持直链访问
- RSS 输出
- 后台：图片上传与维护、相册管理、存储配置、数据统计
- 后台鉴权基于 better-auth，支持双因素认证（TOTP）与 Passkey

**iOS App**

- 与网页端同源的画廊：单页画廊、卡片分享/下载、详情页信息面板
- 本地缓存 + **首次启动可离线**：构建期把站点配置、全部列表元数据与预览图打进包内
- 适配 iPhone / iPad，支持横竖屏两套详情页布局
- 纯 SwiftUI（iOS 17+，Swift 6 严格并发）

## 技术栈

| 层 | 选型 |
|---|---|
| Web 框架 | Next.js 16（App Router，ISR） |
| 数据库 | PostgreSQL（Supabase，`ap-southeast-1` 新加坡） |
| ORM | Prisma |
| 鉴权 | better-auth |
| 对象存储 | Cloudflare R2 + 自定义域 |
| 部署 | Vercel（函数区域 `sin1`，与数据库同区） |
| iOS | SwiftUI + Swift 6，`ImageRenderer` 像素级校验 |

## 目录结构

```
app/                    Next.js 路由（公开页面 / 后台 / API）
components/             组件（相册、查看器、后台、UI）
server/                 数据访问与业务逻辑（Prisma 查询、操作、S3）
prisma/                 schema 与迁移
lib/  hooks/  types/    工具、hooks、类型
ios/                    iOS 工程（PicImpactKit 包 + FelinaGallery App）
scripts/                构建与运维脚本（iOS 工程生成、打包种子、数据库还原）
docs/                   文档（App Store 材料、计划文档）
```

## 本地开发

```bash
pnpm install

# .env（不要提交）
#   DATABASE_URL / DIRECT_URL   PostgreSQL 连接串
#   BETTER_AUTH_SECRET          鉴权密钥
#   BETTER_AUTH_URL             回调地址

pnpm dev
```

数据库迁移与种子：

```bash
npx prisma migrate deploy     # 应用迁移
pnpm prisma:seed              # 初始数据
```

数据库备份与还原（导出为行级 JSON，含真实列名）：

```bash
node scripts/db-dump.mjs                     # 导出到 db-backups/（已被 gitignore）
node scripts/db-restore.mjs                  # 还原最新一份
node scripts/db-restore.mjs db-backups/xxx.json
```

> 还原脚本会从目标库读 `information_schema` 给每个占位符加类型转换 —— 这样 `json/jsonb`
> 与 `timestamp` 列才不会报 `42804`。细节与踩坑记录见脚本内注释。

iOS：

```bash
python3 scripts/ios-project.py    # 由脚本生成 Xcode 工程（唯一来源）
python3 scripts/ios-seed.py       # 刷新打包种子（构建阶段会自动执行，增量）
```

## 安全

- `.env` 及其所有本地变体（`.env.*`，保留 `.env.example`）都在 `.gitignore` 里
- 数据库导出目录 `db-backups/` 含存储密钥等敏感配置，同样被忽略
- 提交前建议扫一遍被跟踪文件里有没有连接串/密钥

## 许可证与来源

本项目基于 [besscroft/PicImpact](https://github.com/besscroft/PicImpact)（MIT）二次开发，
并在其基础上做了大量针对自身需求的改动（界面、性能、数据迁移、iOS 客户端等）。

原始版权声明保留在 [LICENSE](./LICENSE) 中，遵循 MIT 协议；
本项目自身的修改同样以 MIT 协议发布。

第三方代码的出处标注保留在各自文件内（例如 `components/album/webgl-viewer/`
参考了 [Afilmory/afilmory](https://github.com/Afilmory/afilmory)）。
