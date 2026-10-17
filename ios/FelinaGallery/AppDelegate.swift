import PicImpactKit
import UIKit
import UserNotifications

/// 最小 AppDelegate：只做 device token 与通知回调的**转发**。
///
/// ## 为什么必须打破「纯 SwiftUI、无 AppDelegate」这条既有约定
/// SwiftUI 里**没有**「注册远程通知并拿到 device token」的等价 API：
/// `UIApplication.shared.registerForRemoteNotifications()` 的结果只会回到
/// `UIApplicationDelegate` 的
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` 与
/// `application(_:didFailToRegisterForRemoteNotificationsWithError:)` 两个方法上；
/// 通知的点击回调（含"点通知拉起 App"那一次）也只有 `UNUserNotificationCenterDelegate` 收得到。
/// 所以这不是风格选择，而是**唯一入口**（规格 §2.5）——
/// `PicImpactApp` 顶部那句「无 AppDelegate」的注释因此被有意打破，理由记录在此。
///
/// ## 它刻意不持有业务逻辑
/// token → 十六进制、注册/节流、跳转目标解析全在 Kit 的 `PushRegistrar` / `PushRoute`
/// 与 `PushCoordinator` 里（那些能用 `swift test` 覆盖）。这里只做转发，
/// 一行业务判断都不写 —— AppDelegate 不可单测，逻辑放这里就等于放弃覆盖。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // ⚠️ 必须尽早设置：delegate 没设好时，系统**不会**把点击回调投递给我们，
        // 「点通知冷启动」这条路径会直接丢失（表现就是点开只到首页）。
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushCoordinator.shared.handleDeviceToken(PushRegistrar.hexToken(deviceToken))
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushCoordinator.shared.handleRegistrationFailure(error.localizedDescription)
    }
}

// MARK: - 通知回调

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// 前台收到推送：**不弹横幅**（返回空数组），只把它当成"立刻刷新"的信号（规格 §5.4）。
    ///
    /// 为什么：用户此刻正看着画廊，横幅是噪音；画廊自己会刷新，效果等价于
    /// "把 60 秒轮询变成推送即刷新"。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            PushCoordinator.shared.handleForegroundPush()
        }
        completionHandler([])
    }

    /// 用户点了通知（App 在前台/后台运行，或点通知把它从冷启动拉起来）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // ⚠️ 解析必须在**跨 actor 之前**同步做完：`userInfo` 是 `[AnyHashable: Any]`，
        // 不是 Sendable，不能被抓进 `Task { @MainActor in … }` 里（Swift 6 严格并发）。
        // 先降级成 Sendable 的 `PushRoute`，再交给主 actor。
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let route {
                PushCoordinator.shared.handleTap(route)
            }
        }
        completionHandler()
    }
}
