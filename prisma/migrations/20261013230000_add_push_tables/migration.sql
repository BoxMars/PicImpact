-- 推送通知（见 docs/superpowers/specs/2026-10-13-ios-push-notification-design.md §4.1）
--
-- 纯加法：只建两张新表 + 索引 + 一条外键，不触碰任何既有表与数据。
--
-- ⚠️ 本文件**不是** `prisma migrate diff` 的原始输出。
-- 原始输出里还带着一句 `DROP INDEX "images_albums_relation_album_value_imageId_idx"`，
-- 那是**既有 drift**、不是本次变更：那条索引是 20261003130000_add_gallery_indexes 里
-- 用裸 SQL 建的（Prisma schema 表达不了），diff 因而不认识它、想把它删掉。
-- 照抄那份输出就会静默删掉画廊热路径的性能索引。所以这里只保留本次真正新增的部分。

-- CreateTable
CREATE TABLE "push_device" (
    "id" VARCHAR(50) NOT NULL,
    "userId" VARCHAR(50) NOT NULL,
    "token" TEXT NOT NULL,
    "environment" VARCHAR(16) NOT NULL,
    "bundleId" VARCHAR(120) NOT NULL,
    "clientId" VARCHAR(64) NOT NULL,
    "deviceName" VARCHAR(100),
    "systemVersion" VARCHAR(32),
    "appVersion" VARCHAR(32),
    "locale" VARCHAR(16),
    "enabled" SMALLINT NOT NULL DEFAULT 1,
    "last_seen_at" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_at" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP,

    CONSTRAINT "push_device_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "push_delivery" (
    "id" VARCHAR(50) NOT NULL,
    "userId" VARCHAR(50) NOT NULL,
    "deviceId" VARCHAR(50),
    "imageId" VARCHAR(50),
    "environment" VARCHAR(16) NOT NULL,
    "status" VARCHAR(24) NOT NULL,
    "httpStatus" INTEGER,
    "apnsId" VARCHAR(64),
    "reason" VARCHAR(64),
    "created_at" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "push_delivery_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "push_device_token_key" ON "push_device"("token");

-- CreateIndex
CREATE INDEX "push_device_userId_enabled_idx" ON "push_device"("userId", "enabled");

-- CreateIndex
CREATE INDEX "push_delivery_userId_created_at_idx" ON "push_delivery"("userId", "created_at");

-- AddForeignKey
ALTER TABLE "push_device" ADD CONSTRAINT "push_device_userId_fkey" FOREIGN KEY ("userId") REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE;
