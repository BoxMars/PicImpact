import SwiftUI

/// 管理员登录表单（邮箱 + 密码）。
///
/// ## 界面上不出现任何"怎么进来"的提示
/// 这个入口是刻意隐藏的，所以页面上**不写**任何"连点标题三次"之类的说明 ——
/// 那等于把暗门标在门上。想知道入口的人自然知道，不知道的人不该被引导进来。
///
/// ## 为什么不在本地判断"密码对不对"
/// 凭证是否正确只有服务端知道。这里只把用户输入原样交给 `AuthStore`，
/// 再把服务端返回的原文显示出来（见 `errorMessage`）——
/// 本地再编一句"邮箱或密码不正确"会把"请求根本没发出去"和"服务端拒绝了"两种情况混为一谈，
/// 而这两者的排查方式完全不同。
public struct AdminLoginView: View {

    @State private var email = ""
    @State private var password = ""

    private let isBusy: Bool
    private let errorMessage: String?
    private let onCancel: () -> Void
    private let onSubmit: (String, String) -> Void

    public init(
        isBusy: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String, String) -> Void
    ) {
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ScrollView {
            AdminLoginContent(
                email: $email,
                password: $password,
                isBusy: isBusy,
                errorMessage: errorMessage,
                onCancel: onCancel,
                onSubmit: onSubmit
            )
        }
        // 键盘弹起时 ScrollView 才能把被挡住的输入框滚出来
        .adminScrollDismissesKeyboard()
        .background(AnimalTokens.bg)
    }
}

/// 登录界面**除滚动容器以外**的全部内容。
///
/// ## 为什么要把 ScrollView 拆出去
/// 单测用 `ImageRenderer` 栅格化视图来断言"令牌色真的画出来了"，
/// 而实测 `ImageRenderer` 渲染 `ScrollView` 的内容会得到一张**全透明**的图
/// （只有它的 background 画得出来）。拆开之后，纸卡/按钮/错误区这些真正要验的东西
/// 就能在没有滚动容器的层面上被验证。
struct AdminLoginContent: View {

    @Binding var email: String
    @Binding var password: String

    let isBusy: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: (String, String) -> Void

    /// 键盘"下一项"要真的能跳到密码框。
    /// 之前只有 `submitLabel(.next)`，按下去什么都不会发生 —— 而系统密码自动填充
    /// 填完之后用户最常见的动作就是按这个键。
    private enum Field: Hashable { case email, password }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: AnimalTokens.spacingLG) {
            HStack {
                IslandBackButton(label: "关闭", action: onCancel)
                Spacer()
            }

            IslandCard {
                VStack(alignment: .leading, spacing: AnimalTokens.spacingLG) {
                    IslandPageTitle("管理员登录")

                    VStack(spacing: AnimalTokens.spacingMD) {
                        inputField
                        secureInputField
                    }

                    IslandActionButton(
                        isBusy ? "登录中…" : "登录",
                        isEnabled: !isBusy
                    ) {
                        onSubmit(email, password)
                    }
                    .accessibilityIdentifier("admin-login-submit")

                    // 错误区放在按钮**下面**：出现/消失时上面的输入框与按钮一动不动，
                    // 页面不会"跳"一下。放在按钮上方或标题上方都会把下面的内容顶走。
                    errorArea
                }
                .padding(AnimalTokens.spacingLG)
            }
        }
        .padding(AnimalTokens.spacingLG)
    }

    // MARK: - 输入框

    private var inputField: some View {
        TextField("邮箱", text: $email)
            .textContentType(.username)
            .adminKeyboard(.email)
            .submitLabel(.next)
            .focused($focusedField, equals: .email)
            .onSubmit { focusedField = .password }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AnimalSignatures.cardText)
            .tint(AnimalTokens.primary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .islandSurface(fill: AnimalTokens.bg, borderWidth: 1.5, cornerRadius: 14, shadowOffsetY: 2)
            .accessibilityIdentifier("admin-email")
    }

    private var secureInputField: some View {
        SecureField("密码", text: $password)
            .textContentType(.password)
            .adminKeyboard(.password)
            .submitLabel(.go)
            .focused($focusedField, equals: .password)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AnimalSignatures.cardText)
            .tint(AnimalTokens.primary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .islandSurface(fill: AnimalTokens.bg, borderWidth: 1.5, cornerRadius: 14, shadowOffsetY: 2)
            .accessibilityIdentifier("admin-password")
            // 回车即提交，省一次点击
            .onSubmit { onSubmit(email, password) }
    }

    @ViewBuilder
    private var errorArea: some View {
        if let errorMessage {
            HStack(alignment: .top, spacing: AnimalTokens.spacingSM) {
                AnimalIcon(.chat, size: 16)
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AnimalTokens.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 标识符放在 Text 上而不是外层容器：只有真正是无障碍元素的那一层
                    // 才能被 XCUITest 的 `staticTexts[...]` 查到（放在容器上会查不到）
                    .accessibilityIdentifier("admin-login-error")
            }
            .padding(AnimalTokens.spacingSM + 2)
            .islandSurface(
                fill: AnimalTokens.error.opacity(0.08),
                border: AnimalTokens.error,
                borderWidth: 1.5,
                cornerRadius: 12,
                shadowOffsetY: 2
            )
        }
    }
}

/// 键盘相关的修饰符在 macOS 上不存在，而本包**同时**要在 macOS 上跑 `swift test`。
/// 用条件编译把差异收在这里，视图主体就只剩一套写法（与仓库里 `#if canImport(UIKit)`
/// 处理 iOS 专有 API 的做法一致）。
private enum AdminKeyboard {
    case email
    case password
}

private extension View {

    @ViewBuilder
    func adminKeyboard(_ kind: AdminKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .email:
            self
                .keyboardType(.emailAddress)
                // 邮箱被首字母大写或被自动纠错改掉，用户会反复登录失败却看不出原因
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .password:
            self
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func adminScrollDismissesKeyboard() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}
