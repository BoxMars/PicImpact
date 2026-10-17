import Foundation
import Testing

@testable import PicImpactKit

/// 推送注册器的纯逻辑：clientId、token 十六进制化、环境判定、心跳节流、登出停用。
///
/// 这些都是"真机上出问题只能靠猜"的地方（注册没成功＝静默收不到通知），
/// 所以全部用注入的 Keychain / client / 时钟直接断言。
@Suite("推送 · 设备注册")
@MainActor
struct PushRegistrarTests {

    // MARK: - 测试替身

    final class FakePushAPI: PushAPI, @unchecked Sendable {
        var registered: [PushDeviceRegistration] = []
        var unregistered: [String] = []
        var registerResult: Result<PushDeviceSummary, APIError> = .success(FakePushAPI.summary)
        var unregisterResult: Result<Int, APIError> = .success(1)

        static let summary = PushDeviceSummary(
            id: "d1",
            deviceName: "iPhone 16 Pro",
            systemVersion: "18.0",
            appVersion: "1.2.0+42",
            environment: "sandbox",
            enabled: 1,
            clientId: "3F2A1B4C-5D6E-7F80-9A0B-1C2D3E4F5A6B",
            lastSeenAt: "2026-10-13T12:00:00.000Z",
            tokenSuffix: "66778899"
        )

        func registerDevice(_ registration: PushDeviceRegistration) async throws -> PushDeviceSummary {
            registered.append(registration)
            return try registerResult.get()
        }

        func unregisterDevice(clientId: String) async throws -> Int {
            unregistered.append(clientId)
            return try unregisterResult.get()
        }

        func listDevices(cookie: String) async throws -> PushDeviceList {
            PushDeviceList(pushEnabled: true, devices: [Self.summary])
        }
    }

    /// 可推进的时钟。`@unchecked Sendable`：只在主 actor 上被读写（与 PushRegistrar 同一隔离域）。
    final class MutableClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    static let tokenA = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
    static let tokenB = "1122334455667788990011223344556677889900112233445566778899001122"
    static let deviceInfo = PushDeviceInfo(
        deviceName: "iPhone 16 Pro", systemVersion: "18.0", appVersion: "1.2.0+42", locale: "zh-Hans-CN"
    )
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeRegistrar(
        api: FakePushAPI,
        keychain: InMemoryKeychain = InMemoryKeychain(),
        clock: MutableClock,
        ledger: (any PushRegistrationLedger)? = nil
    ) -> PushRegistrar {
        PushRegistrar(
            api: api,
            keychain: keychain,
            environment: "sandbox",
            deviceInfo: Self.deviceInfo,
            ledger: ledger,
            now: { clock.now }
        )
    }

    // MARK: - clientId

    @Test("clientId：首次生成后稳定，换一个实例（同一 Keychain）仍是同一个值")
    func clientIdIsStable() async {
        let keychain = InMemoryKeychain()
        let clock = MutableClock(Self.start)

        let first = makeRegistrar(api: FakePushAPI(), keychain: keychain, clock: clock)
        let generated = await first.prepareClientId()
        #expect(PushRegistrar.isValidClientId(generated), "生成的 id 必须能过服务端的正则：\(generated)")
        let again = await first.prepareClientId()
        #expect(again == generated, "同一实例重复调用必须幂等")

        // 模拟"下一次启动"：新实例、同一块钥匙串
        let second = makeRegistrar(api: FakePushAPI(), keychain: keychain, clock: clock)
        let afterRestart = await second.prepareClientId()
        #expect(afterRestart == generated, "跨启动必须稳定（否则服务端会多出一台设备）")
    }

    @Test("clientId：钥匙串里的值非法时重新生成并覆盖（不把脏数据发给服务端）")
    func clientIdReplacesInvalidStoredValue() async {
        let keychain = InMemoryKeychain()
        await keychain.set(Data("bad id!".utf8), for: PushRegistrar.clientIdKey)
        let registrar = makeRegistrar(api: FakePushAPI(), keychain: keychain, clock: MutableClock(Self.start))

        let generated = await registrar.prepareClientId()
        #expect(generated != "bad id!")
        #expect(PushRegistrar.isValidClientId(generated))
        // 覆盖已经写回钥匙串
        let stored = await keychain.data(for: PushRegistrar.clientIdKey)
        #expect(stored == Data(generated.utf8))
    }

    // MARK: - 格式与环境

    @Test("device token：Data → 小写十六进制串")
    func hexConversion() {
        #expect(PushRegistrar.hexToken(Data([0x00, 0x01, 0xAB, 0xFF])) == "0001abff")
        #expect(PushRegistrar.hexToken(Data()) == "")
    }

    @Test("device token 校验：字符集与长度（不猜 APNs 的具体长度）")
    func tokenValidation() {
        #expect(PushRegistrar.isValidToken(Self.tokenA))
        #expect(PushRegistrar.isValidToken(String(repeating: "a", count: 32)), "32 位是最短合法")
        #expect(PushRegistrar.isValidToken(String(repeating: "F", count: 200)), "200 位是最长合法")
        #expect(PushRegistrar.isValidToken(String(repeating: "a", count: 31)) == false)
        #expect(PushRegistrar.isValidToken(String(repeating: "a", count: 201)) == false)
        #expect(PushRegistrar.isValidToken("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == false, "非十六进制")
        #expect(PushRegistrar.isValidToken("") == false)
    }

    @Test("environment 必须与编译配置配对：Debug=沙箱、Release=生产")
    func environmentMatchesBuildConfiguration() {
        #if DEBUG
        #expect(PushRegistrar.currentEnvironment == "sandbox")
        #else
        #expect(PushRegistrar.currentEnvironment == "production")
        #endif
    }

    // MARK: - 节流（纯函数）

    @Test("节流判据：没注册过 → 注册；同 token 24h 内 → 跳过；超 24h 或 token 变了 → 注册")
    func shouldRegisterRules() {
        let last = PushRegistrationRecord(token: Self.tokenA, registeredAt: Self.start)

        #expect(PushRegistrar.shouldRegister(last: nil, token: Self.tokenA, now: Self.start), "从未注册过")
        let withinWindow = PushRegistrar.shouldRegister(
            last: last, token: Self.tokenA, now: Self.start.addingTimeInterval(23 * 3600)
        )
        #expect(withinWindow == false, "23 小时内不重复注册")
        let afterWindow = PushRegistrar.shouldRegister(
            last: last, token: Self.tokenA, now: Self.start.addingTimeInterval(24 * 3600)
        )
        #expect(afterWindow, "到 24 小时就该心跳一次")
        let tokenChanged = PushRegistrar.shouldRegister(
            last: last, token: Self.tokenB, now: Self.start.addingTimeInterval(60)
        )
        #expect(tokenChanged, "token 变了必须立刻重登记（否则服务端一直往旧 token 推）")
    }

    // MARK: - 注册

    @Test("首次注册：请求字段逐项与服务端契约一致（token 小写化、环境、clientId、设备自述）")
    func firstRegisterSendsContractFields() async {
        let api = FakePushAPI()
        let clock = MutableClock(Self.start)
        let registrar = makeRegistrar(api: api, clock: clock)

        await registrar.register(deviceTokenHex: Self.tokenA.uppercased())

        #expect(api.registered.count == 1)
        let sent = api.registered[0]
        let clientId = await registrar.prepareClientId()
        #expect(sent.token == Self.tokenA, "服务端接受大小写，但统一小写更便于比对")
        #expect(sent.environment == "sandbox")
        #expect(sent.clientId == clientId)
        #expect(sent.deviceName == "iPhone 16 Pro")
        #expect(sent.systemVersion == "18.0")
        #expect(sent.appVersion == "1.2.0+42")
        #expect(sent.locale == "zh-Hans-CN")
        #expect(registrar.lastErrorMessage == nil)
        #expect(registrar.lastRegisteredDevice?.tokenSuffix == "66778899")
    }

    @Test("24 小时内重复注册：一次网络都不发（节流真的生效）")
    func heartbeatIsThrottled() async {
        let api = FakePushAPI()
        let clock = MutableClock(Self.start)
        let registrar = makeRegistrar(api: api, clock: clock)

        await registrar.register(deviceTokenHex: Self.tokenA)
        #expect(api.registered.count == 1)

        clock.now = Self.start.addingTimeInterval(3600)     // 一小时后（例如 App 重开）
        await registrar.register(deviceTokenHex: Self.tokenA)
        #expect(api.registered.count == 1, "节流窗口内不能再打网络")

        clock.now = Self.start.addingTimeInterval(24 * 3600 + 1)
        await registrar.register(deviceTokenHex: Self.tokenA)
        #expect(api.registered.count == 2, "超过 24 小时要做一次心跳")

        // token 变了（重装 / 系统轮换）：不等 24 小时也要立刻重登记
        await registrar.register(deviceTokenHex: Self.tokenB)
        #expect(api.registered.count == 3)
        #expect(api.registered[2].token == Self.tokenB)
    }

    @Test("force 忽略节流：登录 / 刚授权时能立刻注册一次（登出后置回的 enabled 要能改回 1）")
    func forceBypassesThrottle() async {
        let api = FakePushAPI()
        let clock = MutableClock(Self.start)
        let registrar = makeRegistrar(api: api, clock: clock)

        await registrar.register(deviceTokenHex: Self.tokenA)
        await registrar.register(deviceTokenHex: Self.tokenA, force: true)
        #expect(api.registered.count == 2)
    }

    @Test("token 不合法：不发请求，且原因是 invalid_token（模拟器拿不到 token 时就是这条）")
    func invalidTokenIsRejectedLocally() async {
        let api = FakePushAPI()
        let registrar = makeRegistrar(api: api, clock: MutableClock(Self.start))

        await registrar.register(deviceTokenHex: "not-a-token")
        #expect(api.registered.isEmpty)
        #expect(registrar.lastErrorMessage == "invalid_token")
    }

    @Test("不需要登录：没有会话也照常注册（设备与账号无关，装了 App 就该收到通知）")
    func registersWithoutSession() async {
        let api = FakePushAPI()
        let clock = MutableClock(Self.start)
        let ledger = InMemoryPushRegistrationLedger()
        let registrar = makeRegistrar(api: api, clock: clock, ledger: ledger)

        await registrar.register(deviceTokenHex: Self.tokenA)

        #expect(api.registered.count == 1, "没有会话也必须注册成功 —— 这里不能有登录门槛")
        #expect(api.registered[0].clientId.isEmpty == false)
        let after = await ledger.lastRegistration()
        #expect(after != nil, "注册成功要留节流记录")
    }

    @Test("注册失败不抛错，只留下服务端原话（推送不能影响任何主流程）")
    func registerFailureIsSwallowed() async {
        let api = FakePushAPI()
        api.registerResult = .failure(.http(status: 401, code: 401, message: "authentication failed"))
        let clock = MutableClock(Self.start)
        let ledger = InMemoryPushRegistrationLedger()
        let registrar = makeRegistrar(api: api, clock: clock, ledger: ledger)

        await registrar.register(deviceTokenHex: Self.tokenA)   // 不允许抛
        #expect(registrar.lastErrorMessage == "authentication failed")
        // 失败不写节流记录：下一次（网络恢复后）要能重试
        let afterFailure = await ledger.lastRegistration()
        #expect(afterFailure == nil)
    }

    // MARK: - 登出

    @Test("登出：带 clientId 调 DELETE，并清掉节流记录（下次登录必须重新注册）")
    func unregisterDisablesDeviceAndResetsLedger() async {
        let api = FakePushAPI()
        let clock = MutableClock(Self.start)
        let ledger = InMemoryPushRegistrationLedger()
        let registrar = makeRegistrar(api: api, clock: clock, ledger: ledger)

        await registrar.register(deviceTokenHex: Self.tokenA)
        let clientId = await registrar.prepareClientId()
        let afterRegister = await ledger.lastRegistration()
        #expect(afterRegister != nil)

        await registrar.unregister()

        #expect(api.unregistered.count == 1)
        #expect(api.unregistered[0] == clientId, "按 clientId 停用这台设备")
        let afterUnregister = await ledger.lastRegistration()
        #expect(afterUnregister == nil, "登出后记录要清掉")

        // 记录清掉后，即使不 force 也会重新注册（用户重新登录 → enabled 改回 1）
        clock.now = Self.start.addingTimeInterval(60)
        await registrar.register(deviceTokenHex: Self.tokenA)
        #expect(api.registered.count == 2)
    }

    @Test("权限状态映射：denied 时管理页显示去系统设置的入口")
    func authorizationStateDrivesTheSettingsEntry() async {
        let registrar = makeRegistrar(api: FakePushAPI(), clock: MutableClock(Self.start))
        #expect(registrar.isDenied == false)

        registrar.setAuthorization(.denied)
        #expect(registrar.isDenied)

        registrar.setAuthorization(.authorized)
        #expect(registrar.isDenied == false)
    }
}
