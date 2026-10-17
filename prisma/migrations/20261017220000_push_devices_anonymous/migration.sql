-- 推送设备解除「必须绑用户」的约束（2026-10-17）
--
-- 需求纠正：装了 App 的人（家人/朋友）都该收到「有新照片」的通知，**登录只是上传/管理才需要**。
-- 所以：
--   · `push_device.userId` 允许为空（普通 App 用户就是 null）
--   · 外键改成 ON DELETE SET NULL（删用户不该连带删设备）
--   · 索引从 (userId, enabled) 换成 (enabled)：推送筛选看的是 enabled，从来不看 userId
--   · `push_delivery.userId` 同样允许为空（匿名设备的投递日志）
--   · 冷却判据查的是「该设备最近一次成功投递」，补 (deviceId, status, created_at) 索引
--
-- ⚠️ 本文件**不是** `prisma migrate diff` 的原始输出。原始输出里还夹着一句
-- `DROP INDEX "images_albums_relation_album_value_imageId_idx"` —— 那是**既有 drift**
-- （该索引是 20261003130000_add_gallery_indexes 用裸 SQL 建的，Prisma schema 表达不了），
-- 照抄会静默删掉画廊热路径的性能索引。这里只保留本次真正的变更。
--
-- 两张表当前都是空的（push_device 0 行、push_delivery 0 行），所以改动没有数据风险。

-- DropForeignKey
ALTER TABLE "push_device" DROP CONSTRAINT "push_device_userId_fkey";

-- DropIndex
DROP INDEX "push_delivery_userId_created_at_idx";

-- DropIndex
DROP INDEX "push_device_userId_enabled_idx";

-- AlterTable
ALTER TABLE "push_delivery" ALTER COLUMN "userId" DROP NOT NULL;

-- AlterTable
ALTER TABLE "push_device" ALTER COLUMN "userId" DROP NOT NULL;

-- CreateIndex
CREATE INDEX "push_delivery_deviceId_status_created_at_idx" ON "push_delivery"("deviceId", "status", "created_at");

-- CreateIndex
CREATE INDEX "push_delivery_created_at_idx" ON "push_delivery"("created_at");

-- CreateIndex
CREATE INDEX "push_device_enabled_idx" ON "push_device"("enabled");

-- CreateIndex
CREATE INDEX "push_device_clientId_idx" ON "push_device"("clientId");

-- AddForeignKey
ALTER TABLE "push_device" ADD CONSTRAINT "push_device_userId_fkey" FOREIGN KEY ("userId") REFERENCES "user"("id") ON DELETE SET NULL ON UPDATE CASCADE;
