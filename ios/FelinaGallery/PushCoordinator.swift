import PicImpactKit
import UIKit
import UserNotifications

/// App target 的推送接线：系统权限、APNs 注册、前台刷新、点击跳转。
///
/// ## 为什么这些不放 Kit
/// 它用了 `UIApplication.shared` / `UNUserNotificationCenter` / `UNAuthorizationStatus`；
/// 而 Kit 是同时给 iOS（产品）与 macOS（`swift test` 的宿主）编译的
/// （`Package.swift` 的平台列表），这类代码放进去在 macOS 上直接编译失败（规格 §5.6）。
/// 能被单测覆盖的纯逻辑（`clientId`、token 十六进制、环境判定、节流、`userInfo` 解析）
/// 全在 Kit 的 `PushRegistrar` / `PushRoute` 里。
///
/// ## 为什么是单例
/// `UNUserNotificationCenter` 的 delegate 与 device token 回调都落在 `AppDelegate` 上，
/// 而 AppDelegate 由 SwiftUI 自己创建（`@UIApplicationDelegateAdaptor`），
/// 我们无法把 `AppEnvironment` 注进它的初始化。于是这里当**唯一接线点**：
/// AppEnvironment 装配时 `bind(...)`，AppDelegate 只往这里转发（规格 §5.3 的"不持有业务逻辑"）。
@MainActor
final class PushCoordinator {

    static let shared = PushCoordinator()

    /// 接线之前到达的回调先存住。
    ///
    /// 为什么真会发生：点通知冷启动时 `didReceive` 可能早于 `AppEnvironment` 装配完成
    /// （SwiftUI 的 App 实例与场景建立之间有窗口期）。丢掉就等于"点了通知没反应"。
    private var pendingTokens: [String] = []
    private var pendingRoutes: [PushRoute] = []

    private weak var registrar: PushRegistrar?
    private weak var inbox: PushRouteInbox?
    /// 前台收到推送时要刷新什么（画廊 + 管理列表）
    private var onForegroundPush: (() async -> Void)?
    /// 下一次拿到 token 时是否强制注册 —— 进管理页（刚授权 / 刚登录）时置上。
    ///
    /// 登出会把设备置 `enabled=0`，再登录必须立刻改回 1，不能等 24 小时的心跳节流。
    private var forceNextRegistration = false

    private init() {}

    // MARK: - 装配

    /// 由 `AppEnvironment` 在装配完成时调用一次。
    func bind(
        registrar: PushRegistrar,
        inbox: PushRouteInbox,
        onForegroundPush: @escaping () async -> Void
    ) {
        self.registrar = registrar
        self.inbox = inbox
        self.onForegroundPush = onForegroundPush

        // 补发接线之前到达的回调（冷启动场景）
        let tokens = pendingTokens
        let routes = pendingRoutes
        pendingTokens.removeAll()
        pendingRoutes.removeAll()
        for token in tokens { Task { await registrar.register(deviceTokenHex: token) } }
        for route in routes { inbox.put(route) }
    }

    // MARK: - 启动 / 进管理页

    /// 启动时调用（App 一打开就调，**不需要登录**）。
    ///
    /// ## 为什么权限在这里问
    /// 装了 App 的人都该收到「有新照片」的通知 —— 登录只用于上传/管理。
    /// （初版把弹窗藏在管理员登录后面，是设计错误：等于只有站长登录过的手机才收得到。）
    ///
    /// ## 为什么仍然"只问一次"
    /// iOS 的系统弹窗**一辈子只弹一次**：`.notDetermined` 时才申请；已经授权就每次启动
    /// 静默续一次 APNs token（不弹框）；已经拒绝就什么都不做（只能去系统设置里改）。
    func start() async {
        guard let registrar else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let state = Self.state(from: settings.authorizationStatus)
        registrar.setAuthorization(state)

        switch settings.authorizationStatus {
        case .notDetermined:
            // 只申请 `.alert` 与 `.sound`，**不要** `.badge`：本项目不做角标/未读数（规格 §10）
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            registrar.setAuthorization(granted ? .authorized : .denied)
            // 拒绝**不是错误**：静默退化到已有的前台轮询，界面会给"去系统设置"的入口（规格 §2.8）
            guard granted else { return }
        case .denied:
            // 系统不会再弹一次，只有设置里能改。这里什么都不做，避免"点了没反应"的错觉。
            return
        default:
            break
        }

        forceNextRegistration = true
        // 这一步**不会弹框**：只是向 APNs 换一次当前 token，结果回到 AppDelegate
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - AppDelegate 的回调入口

    func handleDeviceToken(_ hexToken: String) {
        guard let registrar else {
            pendingTokens.append(hexToken)
            return
        }
        let force = forceNextRegistration
        forceNextRegistration = false
        Task { await registrar.register(deviceTokenHex: hexToken, force: force) }
    }

    func handleRegistrationFailure(_ reason: String) {
        // 注册失败在真机上的典型原因：没网、模拟器拿不到 token、profile 没开推送能力。
        // 只记日志：用户此刻不需要被打断，功能会退化到前台轮询（规格 §5.5）。
        APILog.push("APNs 注册失败：\(reason)")
    }

    /// 前台收到推送。**不弹横幅**，把它当成"立刻刷新列表"的信号（规格 §5.4）。
    func handleForegroundPush() {
        guard let onForegroundPush else { return }
        Task { await onForegroundPush() }
    }

    /// 用户点了通知（App 运行中或冷启动）。
    func handleTap(_ route: PushRoute) {
        guard let inbox else {
            pendingRoutes.append(route)
            return
        }
        inbox.put(route)
    }

    // MARK: - 系统状态映射

    static func state(from status: UNAuthorizationStatus) -> PushRegistrar.AuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            // 系统加了新状态时按"没问过"处理：宁可下次进管理页再问一遍，也不要误判成已授权
            return .unknown
        }
    }
}
