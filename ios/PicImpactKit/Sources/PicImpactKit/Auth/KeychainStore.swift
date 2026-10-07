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
    func data(for key: String) -> Data?

    /// 写入或覆盖。返回是否成功。
    @discardableResult
    func set(_ data: Data, for key: String) -> Bool

    /// 删除。**幂等**：键本来就不存在也算成功。
    @discardableResult
    func remove(_ key: String) -> Bool
}

/// 基于 `SecItem`（Generic Password）的 Keychain 实现。
///
/// service + account 才是钥匙串里的唯一键，所以这里把 service 固定为 App 的
/// bundle id，account 用调用方给的 key —— 不同用途各占一条，互不覆盖。
public struct KeychainStore: KeychainStoring {

    /// 默认 service。用 bundle id 是为了（a）与别的 App 隔离，
    /// （b）将来换 App 名字时能一眼看出这条凭证属于谁。
    public static let defaultService = "dev.boxz.felina"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    public func set(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        // 先试更新：已经是"存在则覆盖"的语义，且不会因为重复 Add 而返回 errSecDuplicateItem
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        // 更新失败且不是因为"不存在"，说明是真的写不进去（例如缺少权限），不要盲目再 Add
        guard updateStatus == errSecItemNotFound else { return false }

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
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
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
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    @discardableResult
    public func set(_ data: Data, for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
        return true
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
        return true
    }
}
