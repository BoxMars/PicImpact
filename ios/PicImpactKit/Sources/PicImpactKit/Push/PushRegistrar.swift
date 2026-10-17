import Foundation
import Observation

#if os(iOS)
import UIKit
#endif

/// 一次成功注册的记录。
///
/// 存 `token` 是为了识别"token 变了"（重装、恢复备份、系统轮换）。
/// **只看时间戳是不够的**：那样 24 小时内换过 token 的安装永远不会被重新登记，
/// 服务端会一直往旧 token 推 —— 表现就是"注册成功但收不到通知"。
public struct PushRegistrationRecord: Equatable, Sendable {
    public let token: String
    public let registeredAt: Date

    public init(token: String, registeredAt: Date) {
        self.token = token
        self.registeredAt = registeredAt
    }
}

/// 心跳节流记录的持久化。抽成协议的理由与 `KeychainStoring` 一样：
/// "24 小时内不重复注册"这条规则要能脱离真实存储、用注入的时钟直接断言。
public protocol PushRegistrationLedger: Sendable {
    func lastRegistration() async -> PushRegistrationRecord?
    func markRegistered(_ record: PushRegistrationRecord) async
    func reset() async
}

/// Keychain 实现（account 与 clientId 各占一条，service 仍是 `dev.boxz.felina`）。
///
/// 为什么不用 `UserDefaults`：这份记录里有 device token 的副本 ——
/// 它不写进明文 plist（会被 iCloud/iTunes 备份带走），规则与"会话 Cookie 放 Keychain"完全一致
/// （`AppEnvironment.swift` 里那条注释）。用同一个 `KeychainStoring` 还有第二个好处：
/// 单测注入 `InMemoryKeychain` 就能整条链路一起测。
public struct KeychainPushRegistrationLedger: PushRegistrationLedger {

    private struct Stored: Codable {
        let token: String
        /// epoch 秒。**不用** `JSONEncoder` 的日期策略：默认策略会写成 2001 起算的浮点数，
        /// 跨端读的时候最容易差 31 年（本项目在别处踩过同类坑），显式存秒最不容易错。
        let registeredAt: Double
    }

    private let keychain: any KeychainStoring
    private let key: String

    public init(keychain: any KeychainStoring, key: String = PushRegistrar.registrationKey) {
        self.keychain = keychain
        self.key = key
    }

    public func lastRegistration() async -> PushRegistrationRecord? {
        guard let data = await keychain.data(for: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return PushRegistrationRecord(token: stored.token, registeredAt: Date(timeIntervalSince1970: stored.registeredAt))
    }

    public func markRegistered(_ record: PushRegistrationRecord) async {
        let stored = Stored(token: record.token, registeredAt: record.registeredAt.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        _ = await keychain.set(data, for: key)
    }

    public func reset() async {
        _ = await keychain.remove(key)
    }
}

/// 内存实现，给单测与预览用。
public actor InMemoryPushRegistrationLedger: PushRegistrationLedger {

    private var record: PushRegistrationRecord?

    public init(record: PushRegistrationRecord? = nil) {
        self.record = record
    }

    public func lastRegistration() async -> PushRegistrationRecord? { record }

    public func markRegistered(_ record: PushRegistrationRecord) async {
        self.record = record
    }

    public func reset() async {
        record = nil
    }
}

/// 注册请求里那几个"设备自述"字段。
///
/// ## 为什么单独一个类型
/// 它们全都来自 UIKit（`UIDevice`），而 Kit 同时要能在 macOS 上编译（`swift test` 的宿主）。
/// 把 `#if os(iOS)` 收在这一处，`PushRegistrar` 本身就不必到处条件编译。
public struct PushDeviceInfo: Sendable, Equatable {
    public var deviceName: String?
    public var systemVersion: String?
    public var appVersion: String?
    public var locale: String?

    public init(
        deviceName: String? = nil,
        systemVersion: String? = nil,
        appVersion: String? = nil,
        locale: String? = nil
    ) {
        self.deviceName = deviceName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.locale = locale
    }

    public static var current: PushDeviceInfo {
        #if os(iOS)
        let device = UIDevice.current
        // 服务端对这几个字段有 max 长度（deviceName 100 / systemVersion 32 / locale 16），
        // 超了就是 400 invalid_request，所以在这里先截断。
        return PushDeviceInfo(
            deviceName: Self.clamp(device.name, to: 100),
            systemVersion: Self.clamp(device.systemVersion, to: 32),
            appVersion: Self.clamp(APIEnvironment.appVersion, to: 32),
            locale: Self.clamp(Locale.current.identifier, to: 16)
        )
        #else
        return PushDeviceInfo(appVersion: Self.clamp(APIEnvironment.appVersion, to: 32))
        #endif
    }

    static func clamp(_ value: String, to limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}

/// 推送设备注册器：`clientId`、device token、环境判定、注册节流、登出停用。
///
/// ## 它不认识 UserNotifications / UIKit
/// 权限申请与 `registerForRemoteNotifications()` 在 App target（`PushCoordinator`）里 ——
/// 那些 API 在 macOS 上不存在，而 Kit 要能在 macOS 上跑单测（规格 §5.6）。
/// 这里只做**纯逻辑**：能被 `swift test` 逐条覆盖的部分。
///
/// ## 为什么不抛错
/// 推送是**纯加分项**：任何失败都必须静默退化到已有的前台轮询（规格 §5.5）。
/// 设备注册失败不该影响登录、上传、浏览中的任何一件事，所以这里的方法都不会抛。
@Observable
@MainActor
public final class PushRegistrar {

    /// 系统通知权限在本地的快照。Kit 只暴露状态，"去系统设置"那个动作在 App target。
    public enum AuthorizationState: Equatable, Sendable {
        /// 还没问过（或系统给了未知状态）
        case unknown
        /// 用户拒绝过，或后来在设置里关掉 —— 管理页据此显示"去系统设置"
        case denied
        case authorized
    }

    /// Keychain account：这台安装的稳定 id。改成别的名字＝所有老安装换新 id（不会被误伤，
    /// 但服务端会多出一行旧记录），不要随便动。
    nonisolated public static let clientIdKey = "push-client-id"
    /// Keychain account：心跳节流记录
    nonisolated public static let registrationKey = "push-registration"

    /// 心跳间隔：24 小时。规格 §5.2 要求"每次启动（或回前台且超过 24 小时）都做一次心跳"，
    /// 但没必要每次冷启动都打一次网络 —— token 与 enabled 状态不会 24 小时内自己变。
    public static let heartbeatInterval: TimeInterval = 24 * 60 * 60

    public private(set) var clientId: String?
    public private(set) var authorization: AuthorizationState = .unknown
    /// 最近一次注册/停用失败的原因。只用于日志与诊断界面，**不驱动任何界面报错**。
    public private(set) var lastErrorMessage: String?
    /// 最近一次服务端确认过的设备行（诊断用）
    public private(set) var lastRegisteredDevice: PushDeviceSummary?

    private let api: any PushAPI
    private let keychain: any KeychainStoring
    private let ledger: any PushRegistrationLedger
    private let environment: String
    private let deviceInfo: PushDeviceInfo
    private let now: @Sendable () -> Date

    public init(
        api: any PushAPI,
        keychain: any KeychainStoring,
        environment: String = PushRegistrar.currentEnvironment,
        deviceInfo: PushDeviceInfo = .current,
        ledger: (any PushRegistrationLedger)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.keychain = keychain
        self.ledger = ledger ?? KeychainPushRegistrationLedger(keychain: keychain)
        self.environment = environment
        self.deviceInfo = deviceInfo
        self.now = now
    }

    // MARK: - 派生状态

    /// 管理页据此显示「通知已关闭 · 去系统设置」
    public var isDenied: Bool { authorization == .denied }

    // MARK: - 环境与格式（纯函数，单测直接断言）

    /// 设备 token 的来源环境，**必须与 token 配对**：
    /// Debug 包的 entitlements 是 `aps-environment = development`，拿到的是沙箱 token；
    /// TestFlight / App Store 包是 production。服务端按它选 APNs 端点与 key，
    /// 配错的表现是"静默不发"或 `BadDeviceToken`，极难定位（规格 §2.3、§9.2）。
    public static var currentEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// `Data` → 小写十六进制串（APNs device token 的线上形态）。
    public static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// 与服务端 `DEVICE_TOKEN_PATTERN` 同一套宽松校验：
    /// 官方明确"不要假设 device token 长度"，所以只挡字符集与明显异常的区间。
    public static func isValidToken(_ hex: String) -> Bool {
        guard (32...200).contains(hex.count) else { return false }
        // `Character.isHexDigit` 只认 ASCII 0-9a-fA-F（全角不会通过）
        return hex.allSatisfy(\.isHexDigit)
    }

    /// 与服务端 `CLIENT_ID_PATTERN` 一致：`^[A-Za-z0-9_-]{8,64}$`
    public static func isValidClientId(_ value: String) -> Bool {
        guard (8...64).contains(value.count) else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    /// 需不需要现在注册。两个条件之一成立就要：
    /// 1. **token 变了** —— 立刻重登记（服务端按 token upsert，旧 token 会被换掉）；
    /// 2. 距上次成功注册已超过 `interval`。
    public static func shouldRegister(
        last: PushRegistrationRecord?,
        token: String,
        now: Date,
        interval: TimeInterval = PushRegistrar.heartbeatInterval
    ) -> Bool {
        guard let last else { return true }
        if last.token != token { return true }
        return now.timeIntervalSince(last.registeredAt) >= interval
    }

    // MARK: - clientId

    /// 取本机的 `clientId`，没有就生成一个存进 Keychain。
    ///
    /// 幂等。App 启动时调一次就够了（上传请求头要在第一次上传前就有值）。
    @discardableResult
    public func prepareClientId() async -> String {
        if let clientId { return clientId }

        if let data = await keychain.data(for: Self.clientIdKey),
           let stored = String(data: data, encoding: .utf8),
           Self.isValidClientId(stored) {
            clientId = stored
            return stored
        }

        let generated = UUID().uuidString
        // 写不进去（缺权限/钥匙串异常）也照用：它只影响"自己传的不通知自己"与换账号时的归属，
        // 不是凭证，不值得像会话那样阻断流程；但**必须留下痕迹**。
        let stored = await keychain.set(Data(generated.utf8), for: Self.clientIdKey)
        if !stored {
            APILog.push("clientId 未能写入钥匙串（本次运行仍可用，重启后会换新 id）")
        }
        clientId = generated
        APILog.push("clientId 已生成 suffix=\(generated.suffix(6))")
        return generated
    }

    /// 由 App target 在查到系统权限状态后写入（Kit 不认识 `UNAuthorizationStatus`）。
    public func setAuthorization(_ state: AuthorizationState) {
        authorization = state
    }

    // MARK: - 注册 / 停用

    /// 用当前 device token 注册（或心跳更新）这台设备。**不需要登录**（服务端这个接口是公开的）。
    ///
    /// - Parameter force: 忽略 24 小时节流，**立刻**注册一次。
    ///   刚授权、刚进前台时用它 —— 用户关掉通知会把设备置 `enabled=0`，重新打开必须能改回 1。
    ///
    /// 永不抛错（见类型说明）。
    public func register(deviceTokenHex: String, force: Bool = false) async {
        let token = deviceTokenHex.lowercased()
        guard Self.isValidToken(token) else {
            // 这里几乎只有一个原因：AppDelegate 转发来的 `Data` 是空的（模拟器/没连上 APNs）。
            lastErrorMessage = "invalid_token"
            APILog.push("register 跳过：token 格式不合法 length=\(token.count)")
            return
        }

        let clientId = await prepareClientId()
        let last = await ledger.lastRegistration()
        let timestamp = now()
        guard force || Self.shouldRegister(last: last, token: token, now: timestamp) else {
            APILog.push("register 跳过：节流中（距上次 \(Int(timestamp.timeIntervalSince(last?.registeredAt ?? timestamp)))s）")
            return
        }

        let registration = PushDeviceRegistration(
            token: token,
            environment: environment,
            clientId: clientId,
            deviceName: deviceInfo.deviceName,
            systemVersion: deviceInfo.systemVersion,
            appVersion: deviceInfo.appVersion,
            locale: deviceInfo.locale
        )
        do {
            let device = try await api.registerDevice(registration)
            await ledger.markRegistered(PushRegistrationRecord(token: token, registeredAt: timestamp))
            lastRegisteredDevice = device
            lastErrorMessage = nil
            // 只记 token 的长度与后 4 位：token 决定"往哪台设备推"，与凭证同级（见 APILog 的说明）
            APILog.push("register ok tokenSuffix=\(device.tokenSuffix) env=\(device.environment) enabled=\(device.enabled)")
        } catch {
            lastErrorMessage = Self.describe(error)
            APILog.push("register failed error=\(lastErrorMessage ?? "")")
        }
    }

    /// 停用这台设备（用户关掉通知 / 卸装前）。服务端置 `enabled=0`，不物理删，保留排障线索。
    ///
    /// **尽力而为**：断网时 DELETE 会失败，那时设备会暂时停留在"仍启用"。
    /// 这里不重试、不抛错 —— 下次启动的强制注册会把 `enabled` 改回 1，语义仍然自洽。
    public func unregister() async {
        let clientId = await prepareClientId()
        do {
            let disabled = try await api.unregisterDevice(clientId: clientId)
            APILog.push("unregister ok disabled=\(disabled)")
            lastRegisteredDevice = nil
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = Self.describe(error)
            APILog.push("unregister failed error=\(lastErrorMessage ?? "")")
        }
        // 无论服务端成没成功都清掉节流记录：登出后下一次登录必须真的重新注册
        await ledger.reset()
    }

    /// 失败的界面化文案：优先服务端原话（`invalid_token` / `authentication failed`）。
    static func describe(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        if let serverMessage = apiError.serverMessage, !serverMessage.isEmpty { return serverMessage }
        return apiError.errorDescription ?? "推送注册失败"
    }
}
