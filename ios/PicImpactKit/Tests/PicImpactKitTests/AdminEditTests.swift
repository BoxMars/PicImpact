import Foundation
import Testing

@testable import PicImpactKit

/// 编辑接口的请求构造。字段名错一个服务端就 400/500，而真机上只会显示一句"保存失败"。
@Suite("编辑 · 请求构造")
struct AdminEditRequestTests {

    private let origin = URL(string: "https://felina.boxz.dev")!
    private let cookie = "session=abc"

    @Test("改标题/详情/标签：PUT /api/v1/images/update，三个必填字段必须回传")
    func updateRequestShape() throws {
        let update = AdminImageUpdate(
            id: "clx1",
            url: "https://felina-asset.boxz.dev/images/daily/a.jpeg",
            width: 4032,
            height: 3024,
            title: "新标题",
            detail: "新详情",
            labels: ["生日", "大福"]
        )
        let request = try AdminImageClient.updateRequest(siteOrigin: origin, update: update, cookie: cookie)

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/images/update")
        #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "clx1")
        // 这三个是服务端的硬校验（缺一个就 500）
        #expect(json["url"] as? String == "https://felina-asset.boxz.dev/images/daily/a.jpeg")
        #expect(json["width"] as? Int == 4032)
        #expect(json["height"] as? Int == 3024)
        #expect(json["title"] as? String == "新标题")
        #expect(json["detail"] as? String == "新详情")
        #expect(json["labels"] as? [String] == ["生日", "大福"])
        // 刻意不发：preview/blurhash/show 由服务端负责，sort 见 AdminImageUpdate 的说明
        #expect(json["sort"] == nil)
        #expect(json["preview_url"] == nil)
        #expect(json["blurhash"] == nil)
    }

    @Test("显示/隐藏：PUT /api/v1/images/update-show，体里只有 id 与 show")
    func updateShowRequestShape() throws {
        let request = try AdminImageClient.updateShowRequest(siteOrigin: origin, id: "clx1", show: 1, cookie: cookie)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/images/update-show")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.count == 2)
        #expect(json["id"] as? String == "clx1")
        #expect(json["show"] as? Int == 1)
    }

    @Test("换相册：PUT /api/v1/images/update-Album，发的是相册 **id**")
    func updateAlbumRequestShape() throws {
        let request = try AdminImageClient.updateAlbumRequest(
            siteOrigin: origin, imageId: "clx1", albumId: "cmmhvwnk10000l1047odijqq5", cookie: cookie
        )
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/images/update-Album")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["imageId"] as? String == "clx1")
        #expect(json["albumId"] as? String == "cmmhvwnk10000l1047odijqq5")
    }
}

/// 编辑之后列表**就地更新**（不整页重拉），失败要把服务端原话显示出来。
@Suite("编辑 · 列表状态")
@MainActor
struct AdminImageListEditingTests {

    /// 记录调用、可注入失败的假管理接口
    final class FakeAdminAPI: AdminImageAPI, @unchecked Sendable {
        var updates: [AdminImageUpdate] = []
        var shows: [(id: String, show: Int)] = []
        var albums: [(imageId: String, albumId: String)] = []
        var updateError: APIError?
        var listResult: AdminImagePage

        init(listResult: AdminImagePage) { self.listResult = listResult }

        func signUpload(filename: String, contentType: String, albumValue: String, size: Int, cookie: String) async throws -> SignedUpload {
            throw APIError.transport("不该被调用")
        }
        func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage {
            throw APIError.transport("不该被调用")
        }
        func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage {
            listResult
        }
        func deleteImage(id: String, cookie: String) async throws {}
        func updateImage(_ update: AdminImageUpdate, cookie: String) async throws {
            if let updateError { throw updateError }
            updates.append(update)
        }
        func updateImageShow(id: String, show: Int, cookie: String) async throws {
            if let updateError { throw updateError }
            shows.append((id, show))
        }
        func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws {
            if let updateError { throw updateError }
            albums.append((imageId, albumId))
        }
    }

    private func makePage() -> AdminImagePage {
        let json = """
        {"page":1,"pageSize":24,"total":1,"hasMore":false,"items":[
          {"id":"clx1","url":"https://x/a.jpeg","previewUrl":"https://x/p.webp","title":"旧标题","detail":"",
           "width":4032,"height":3024,"show":0,"showOnMainpage":0,"labels":["旧标签"],
           "createdAt":"2026-10-07T09:12:43.471Z","albumValue":"/daily","albumName":"大福日常",
           "exif":{"model":"iPhone 17","lensModel":"","dataTime":"2026:10:07 16:26:04"}}]}
        """
        return try! APIDecoding.makeDecoder().decode(AdminImagePage.self, from: Data(json.utf8))
    }

    /// 列表编辑测试不涉及相册拉取，给一个空实现即可
    struct StubAlbumSource: AlbumListProviding {
        func albums() async throws -> [AlbumDTO] { [] }
    }

    private func makeStore(_ api: FakeAdminAPI) -> AdminImageListStore {
        AdminImageListStore(api: api, albumSource: StubAlbumSource(), cookie: { "session=abc" })
    }

    @Test("保存元数据：调 update，并就地改掉本地那一条")
    func saveMetadataUpdatesInPlace() async {
        let api = FakeAdminAPI(listResult: makePage())
        let store = makeStore(api)
        await store.loadFirstPage()

        let ok = await store.saveMetadata(id: "clx1", title: "新标题", detail: "新详情", labels: ["生日"])

        #expect(ok)
        #expect(api.updates.count == 1)
        #expect(api.updates[0].title == "新标题")
        // 必填字段取自列表里那一条（不是空值）
        #expect(api.updates[0].url == "https://x/a.jpeg")
        #expect(api.updates[0].width == 4032)
        #expect(store.images[0].title == "新标题")
        #expect(store.images[0].labels == ["生日"])
        #expect(store.total == 1, "就地更新不该改动 total")
    }

    @Test("显示/隐藏：调 update-show 并把状态写回列表")
    func setVisibilityUpdatesInPlace() async {
        let api = FakeAdminAPI(listResult: makePage())
        let store = makeStore(api)
        await store.loadFirstPage()

        #expect(await store.setVisibility(id: "clx1", show: 1))
        #expect(api.shows.count == 1)
        #expect(api.shows[0].show == 1)
        #expect(store.images[0].show == 1)
    }

    @Test("换相册：调 update-Album（发相册 id）并把归属写回列表")
    func moveToAlbumUpdatesInPlace() async {
        let api = FakeAdminAPI(listResult: makePage())
        let store = makeStore(api)
        await store.loadFirstPage()

        #expect(await store.moveToAlbum(id: "clx1", albumId: "alb1", albumValue: "/trip", albumName: "旅行"))
        #expect(api.albums.count == 1)
        #expect(api.albums[0].albumId == "alb1")
        #expect(store.images[0].albumValue == "/trip")
        #expect(store.images[0].albumName == "旅行")
    }

    @Test("失败：返回 false、显示服务端原话、列表保持不变（用户能直接重试）")
    func failureKeepsListIntact() async {
        let api = FakeAdminAPI(listResult: makePage())
        api.updateError = .http(status: 500, code: nil, message: "Image link cannot be empty")
        let store = makeStore(api)
        await store.loadFirstPage()

        let ok = await store.saveMetadata(id: "clx1", title: "新标题", detail: "", labels: [])

        #expect(ok == false)
        #expect(store.errorMessage == "Image link cannot be empty")
        #expect(store.images[0].title == "旧标题", "失败时不能改本地数据")
    }

    @Test("列表 401：必须说是「会话失效」，不能只是空列表")
    func unauthorizedSurfacesAsSessionExpiry() async {
        struct UnauthorizedAPI: AdminImageAPI {
            func signUpload(filename: String, contentType: String, albumValue: String, size: Int, cookie: String) async throws -> SignedUpload { throw APIError.transport("x") }
            func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage { throw APIError.transport("x") }
            func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage {
                throw APIError.http(status: 401, code: nil, message: "authentication failed")
            }
            func deleteImage(id: String, cookie: String) async throws {}
            func updateImage(_ update: AdminImageUpdate, cookie: String) async throws {}
            func updateImageShow(id: String, show: Int, cookie: String) async throws {}
            func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws {}
        }
        let store = AdminImageListStore(api: UnauthorizedAPI(), albumSource: StubAlbumSource(), cookie: { "session=stale" })
        await store.loadFirstPage()

        #expect(store.images.isEmpty)
        #expect(store.sessionExpired, "401 必须被识别出来，界面才能给出重新登录入口")
        #expect(store.errorMessage == "登录状态已失效，请重新登录", "不能只说「没有图片」：\(store.errorMessage ?? "-")")
    }

    @Test("列表里没有这一条：说清楚原因，不能静默失败")
    func missingItemExplainsItself() async {
        let api = FakeAdminAPI(listResult: makePage())
        let store = makeStore(api)
        await store.loadFirstPage()

        let ok = await store.saveMetadata(id: "不存在", title: "x", detail: "", labels: [])
        #expect(ok == false)
        #expect(store.errorMessage?.contains("不在当前列表") == true)
        #expect(api.updates.isEmpty)
    }

    @Test("会话失效：不发请求，直接提示重新登录")
    func missingSessionSkipsRequest() async {
        let api = FakeAdminAPI(listResult: makePage())
        let store = AdminImageListStore(api: api, albumSource: StubAlbumSource(), cookie: { nil })
        await store.loadFirstPage()

        let ok = await store.saveMetadata(id: "clx1", title: "x", detail: "", labels: [])
        #expect(ok == false)
        #expect(api.updates.isEmpty)
        #expect(store.errorMessage?.contains("登录状态已失效") == true)
    }
}

/// 标签输入框的解析规则（用户在手机上打字，标点习惯很杂）
@Suite("编辑 · 标签解析")
struct AdminImageEditDraftTests {

    @Test("中英文逗号、换行都当分隔符；去空白、去空项、保序去重")
    func parsesLabels() {
        #expect(AdminImageEditDraft.parseLabels("生日, 大福，旅行,, 生日\n蛋糕") == ["生日", "大福", "旅行", "蛋糕"])
        #expect(AdminImageEditDraft.parseLabels("   ") == [])
        #expect(AdminImageEditDraft.parseLabels("单个") == ["单个"])
    }

    @Test("回填到输入框：按「逗号+空格」拼，再解析回来必须一模一样")
    func formatRoundTrip() {
        let labels = ["生日", "大福"]
        #expect(AdminImageEditDraft.formatLabels(labels) == "生日, 大福")
        #expect(AdminImageEditDraft.parseLabels(AdminImageEditDraft.formatLabels(labels)) == labels)
        #expect(AdminImageEditDraft.formatLabels([]).isEmpty)
    }
}
