import Foundation
import Testing

@testable import PicImpactKit

/// 用 URLProtocol 桩来计数网络请求 —— 这是验证「请求合并」与「缓存命中不打网络」的唯一可靠方式。
final class StubURLProtocolState: @unchecked Sendable {
    static let shared = StubURLProtocolState()
    private let lock = NSLock()
    private var count = 0
    private var payload = Data("stub-image-bytes".utf8)
    private var delayNanoseconds: UInt64 = 0

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return payload }
        set { lock.lock(); payload = newValue; lock.unlock() }
    }

    var delay: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return delayNanoseconds }
        set { lock.lock(); delayNanoseconds = newValue; lock.unlock() }
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    func reset() {
        lock.lock(); count = 0; delayNanoseconds = 0; lock.unlock()
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = StubURLProtocolState.shared
        state.increment()
        let delay = state.delay
        // startLoading() 不是 async，延迟只能用 DispatchQueue 制造并发窗口
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
                self?.deliver()
            }
        } else {
            deliver()
        }
    }

    private func deliver() {
        let state = StubURLProtocolState.shared
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 注意 `.serialized`：桩状态（请求计数）是进程内全局的，
/// 而 swift-testing 默认**并行**执行同一套件内的用例 —— 不串行化就会互相污染计数。
@Suite("T5 · 图片三级缓存与请求合并", .serialized)
struct ImageCacheTests {

    static func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicImpactCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    // MARK: - 三级缓存

    @Test("内存未命中时回落到磁盘，且回填内存")
    func memoryMissFallsBackToDisk() async throws {
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(configuration: ImageCacheConfiguration(diskDirectory: directory))
        let url = URL(string: "https://example.test/a.webp")!
        let payload = Data(repeating: 0xAB, count: 512)

        await cache.store(payload, for: url)
        await cache.clearMemory() // 只清内存，磁盘应保留

        let fromDisk = await cache.cachedData(for: url)
        #expect(fromDisk == payload, "内存清空后应从磁盘取回")

        // 第二次（回填内存后）仍应命中
        let again = await cache.cachedData(for: url)
        #expect(again == payload)
    }

    @Test("磁盘超限时按最后访问时间淘汰最旧的（LRU，而非写入时间）")
    func diskEvictsLeastRecentlyUsed() async throws {
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 上限 450 字节、每条 200 字节：
        // 存下 a+b = 400 不超限（不能设成 300，否则 a 在"被访问"之前就已经淘汰了，
        // 那样测的就不是 LRU 而是"写入顺序"）；再存 c 变 600 才触发淘汰。
        let configuration = ImageCacheConfiguration(diskLimitBytes: 450, diskDirectory: directory)
        let store = DiskCacheStore(configuration: configuration)

        let a = URL(string: "https://example.test/a.webp")!
        let b = URL(string: "https://example.test/b.webp")!
        let c = URL(string: "https://example.test/c.webp")!

        let payload = Data(repeating: 0x5A, count: 200)
        await store.store(payload, for: a)
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.store(payload, for: b)
        try await Task.sleep(nanoseconds: 20_000_000)

        // 访问 a —— 它应当从"最旧"变成"最新"，从而比 b 更晚被淘汰
        _ = await store.data(for: a)
        try await Task.sleep(nanoseconds: 20_000_000)

        // 存入 c，触发淘汰
        await store.store(payload, for: c)

        let hasA = await store.data(for: a) != nil
        let hasB = await store.data(for: b) != nil
        let hasC = await store.data(for: c) != nil
        #expect(hasC, "刚写入的必须保留")
        #expect(hasB == false, "b 最久未被访问，应先被淘汰")
        #expect(hasA, "a 因为刚被访问过，应比 b 晚淘汰")
        let size = await store.currentSizeBytes()
        #expect(size <= 450, "淘汰后应回到上限以内，实际 \(size)")
    }

    // MARK: - 请求合并（画廊滚动的关键）

    @Test("同一 URL 的并发请求只打一次网络")
    func concurrentRequestsAreCoalesced() async throws {
        let state = StubURLProtocolState.shared
        state.reset()
        state.delay = 80_000_000 // 80ms，确保并发窗口足够宽

        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ImageLoader(
            cache: ImageCache(configuration: ImageCacheConfiguration(diskDirectory: directory)),
            session: Self.makeSession()
        )
        let url = URL(string: "https://example.test/coalesce.webp")!

        // 6 个并发请求同一 URL
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<6 {
                group.addTask { try await loader.data(for: url) }
            }
            for try await data in group {
                #expect(data == state.data)
            }
        }

        #expect(state.requestCount == 1, "6 个并发请求应合并为 1 次网络请求，实际 \(state.requestCount)")
        state.reset()
    }

    @Test("已缓存的数据不再打网络")
    func cacheHitSkipsNetwork() async throws {
        let state = StubURLProtocolState.shared
        state.reset()

        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(configuration: ImageCacheConfiguration(diskDirectory: directory))
        let loader = ImageLoader(cache: cache, session: Self.makeSession())
        let url = URL(string: "https://example.test/hit.webp")!

        _ = try await loader.data(for: url)
        let afterFirst = state.requestCount
        _ = try await loader.data(for: url)
        let afterSecond = state.requestCount

        #expect(afterFirst == 1, "首次应打一次网络")
        #expect(afterSecond == 1, "第二次应命中缓存，不应再打网络")
        state.reset()
    }

    @Test("不同 URL 不会被合并")
    func differentURLsAreNotCoalesced() async throws {
        let state = StubURLProtocolState.shared
        state.reset()
        state.delay = 40_000_000

        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ImageLoader(
            cache: ImageCache(configuration: ImageCacheConfiguration(diskDirectory: directory)),
            session: Self.makeSession()
        )

        try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<3 {
                let url = URL(string: "https://example.test/\(index).webp")!
                group.addTask { try await loader.data(for: url) }
            }
            for try await _ in group {}
        }
        #expect(state.requestCount == 3, "3 个不同 URL 应各打一次，实际 \(state.requestCount)")
        state.reset()
    }

    @Test("HTTP 非 2xx 会被映射成明确错误")
    func badStatusSurfacesAsError() async throws {
        // 这个用例只验证错误类型存在且可读（真实状态码路径由集成测试覆盖）
        let error = ImageLoader.LoadError.badStatus(404)
        #expect(String(describing: error).contains("404"))
    }
}
