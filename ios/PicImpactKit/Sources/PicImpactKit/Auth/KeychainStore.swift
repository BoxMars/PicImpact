import Foundation
import Security

/// Keychain 的读写接口。
///
/// ## 为什么要抽一层协议
/// 会话 Cookie 是**凭证**：它一旦泄漏，别人就能以你的身份调管理接口。
/// 所以它既不能放 `UserDefaults`（明文 plist，会被 iCloud/iTunes 备份带走），
/// 也不适合每次都在测试里去动系统钥匙串（测试环境可能没有可用的登录钥匙串）。
///
/// 接口抽出来之后：
/// - `AuthStore` 的状态机测试注入内存实现，断言"登录后写入、登出后删除"
/// - 真实实现（`KeychainStore`）另有一组针对钥匙串本身的读写测试
///
/// 两边各自测自己该负责的那一半，不会互相掩盖失败。
public protocol KeychainStoring: Sendable {

    /// 取数据。键不存在时返回 nil（而不是抛错）—— "没有会话"是正常状态，不是错误。
    ///
    /// ⚠️ 为什么是 `async`：实现里是 Security 的**同步** `SecItem*`。真机上钥匙串
    /// 需要解锁、设备繁忙时这些调用可能阻塞很久甚至挂住 —— 而调用方（`AuthStore`）
    /// 是 `@MainActor`，同步调用就等于**阻塞主线程**（用户看到的就是"点登录卡住"）。
    /// 改成 async 之后，实现必须自己找地方跑，主线程不再被它挡住。
    func data(for key: String) async -> Data?

    /// 写入或覆盖。返回是否成功。失败**必须**被调用方处理 —— 写不进去就意味着"没有会话"。
    @discardableResult
    func set(_ data: Data, for key: String) async -> Bool

    /// 删除。**幂等**：键本来就不存在也算成功。
    @discardableResult
    func remove(_ key: String) async -> Bool
}

/// 基于 `SecItem`（Generic Password）的 Keychain 实现。
///
/// service + account 才是钥匙串里的唯一键，所以这里把 service 固定为 App 的
/// bundle id，account 用调用方给的 key —— 不同用途各占一条，互不覆盖。
/// ⚠️ 用 `actor` 而不是 `struct`，是为了**确定性地**把 Security 的同步调用挪出主线程。
///
/// 为什么不用"nonisolated async 函数"：那条路是否继承调用方的 actor 取决于语言版本的默认行为
/// （Swift 6.2 的 `nonisolated(nonsending)` 就可能让 async 函数继续跑在调用方 actor 上）。
/// actor 的执行器与主 actor 无关，这一点不依赖任何默认行为，也就能被推理和测试。
public actor KeychainStore: KeychainStoring {

    /// 默认 service。用 bundle id 是为了（a）与别的 App 隔离，
    /// （b）将来换 App 名字时能一眼看出这条凭证属于谁。
    public static let defaultService = "dev.boxz.felina"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func data(for key: String) async -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let started = Date()
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let ms = Date().timeIntervalSince(started) * 1000
        let data = item as? Data
        // 真机上"读不到会话"曾经表现为管理页空白且没有任何提示，所以这里把
        // 状态码与耗时写进日志（**不记数据内容**）。errSecItemNotFound = 没存过。
        APILog.credentials("keychain.read key=\(key) status=\(status) bytes=\(data?.count ?? 0) ms=\(String(format: "%.1f", ms))")
        return status == errSecSuccess ? data : nil
    }

    @discardableResult
    public func set(_ data: Data, for key: String) async -> Bool {
        let query = baseQuery(key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        // 先试更新：已经是"存在则覆盖"的语义，且不会因为重复 Add 而返回 errSecDuplicateItem
        let updateStarted = Date()
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            APILog.credentials("keychain.update key=\(key) ok ms=\(Self.ms(since: updateStarted))")
            return true
        }
        // 更新失败且不是因为"不存在"，说明是真的写不进去（例如缺少权限），不要盲目再 Add
        guard updateStatus == errSecItemNotFound else {
            // errSecMissingEntitlement(-34018) 等都会走到这里：**必须留下痕迹**，
            // 否则真机上就是"登录看着成功、之后所有请求都没有会话"。
            APILog.credentials("keychain.update key=\(key) FAILED status=\(updateStatus) ms=\(Self.ms(since: updateStarted))")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        #if os(iOS)
        // kSecAttrAccessible 只在 iOS 的（数据保护）钥匙串上有效，macOS 上传进去会直接报错，
        // 所以用条件编译隔开 —— 单测在 macOS 上跑，不能因此失败。
        //
        // AfterFirstUnlock：设备重启后只要用户解开过一次锁，App 就能读到会话。
        // 用 WhenUnlocked 的话，后台被唤醒（推送/刷新）时读不到，用户会莫名其妙被登出。
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let addStarted = Date()
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        APILog.credentials("keychain.add key=\(key) status=\(addStatus) ms=\(Self.ms(since: addStarted))")
        return addStatus == errSecSuccess
    }

    private static func ms(since start: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(start) * 1000)
    }

    @discardableResult
    public func remove(_ key: String) async -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        // errSecItemNotFound 也算成功：登出时"本来就没存过"和"删掉了"对调用方没有区别，
        // 让调用方为此写分支只会多一处可能写错的地方。
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// 内存实现。给测试与预览用 —— 它不是"降级方案"，App 里永远用 `KeychainStore`。
public actor InMemoryKeychain: KeychainStoring {

    private var storage: [String: Data] = [:]
    /// 读了几次。用来断言"每个请求都去读钥匙串"这件事没有再发生
    /// （真机事故：主线程被同步 SecItemCopyMatching 拖住）。
    public private(set) var dataReadCount = 0
    /// 让测试能注入"写不进去"（真机上真的会发生：缺少权限、钥匙串异常）
    private let failWrites: Bool

    public init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    public func data(for key: String) async -> Data? {
        dataReadCount += 1
        return storage[key]
    }

    @discardableResult
    public func set(_ data: Data, for key: String) async -> Bool {
        guard !failWrites else { return false }
        storage[key] = data
        return true
    }

    @discardableResult
    public func remove(_ key: String) async -> Bool {
        storage[key] = nil
        return true
    }
}
