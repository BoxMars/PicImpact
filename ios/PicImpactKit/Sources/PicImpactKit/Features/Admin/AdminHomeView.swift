import SwiftUI

/// 管理页：显示当前账号 + 登出。
///
/// ## 为什么只放"真有的东西"
/// 这一页现在只有账号信息与登出。**不写**"图片上传尚未实现"之类的占位说明 ——
/// 那既不告诉用户任何有用的信息，又会让页面看起来像半成品。
/// 后续上传功能做好了直接加进来即可。
///
/// 登出必须现在就做对：它是这条链路上唯一会销毁凭证的动作，
/// 留到后面补很容易漏掉"清 Keychain"这一步，表现成"点了登出，重启又登录上了"。
public struct AdminHomeView: View {

    private let user: AuthUser
    private let isBusy: Bool
    private let onSignOut: () -> Void
    private let onClose: () -> Void

    public init(
        user: AuthUser,
        isBusy: Bool = false,
        onSignOut: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.user = user
        self.isBusy = isBusy
        self.onSignOut = onSignOut
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            AdminAccountContent(user: user, isBusy: isBusy, onSignOut: onSignOut, onClose: onClose)
        }
        .background(AnimalTokens.bg)
    }
}

/// 管理页**除滚动容器以外**的全部内容。
///
/// 与 `AdminLoginContent` 拆开的理由相同：`ImageRenderer` 渲染不出 `ScrollView`
/// 里的内容（实测得到全透明图），而"纸卡与登出按钮的令牌色画出来了没有"必须能断言 ——
/// 这一页在真机上只有真的登录成功才会出现，实施者没有密码，看不到它。
struct AdminAccountContent: View {

    let user: AuthUser
    let isBusy: Bool
    let onSignOut: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: AnimalTokens.spacingLG) {
            HStack {
                IslandBackButton(label: "关闭", action: onClose)
                Spacer()
            }

            IslandCard {
                VStack(alignment: .leading, spacing: AnimalTokens.spacingMD) {
                    IslandPageTitle("管理后台")

                    IslandRow(label: "邮箱", value: user.email)
                    if user.displayName != user.email {
                        IslandRow(label: "昵称", value: user.displayName)
                    }
                }
                .padding(AnimalTokens.spacingLG)
            }

            IslandActionButton("登出", tone: .danger, isEnabled: !isBusy, action: onSignOut)
                .accessibilityIdentifier("admin-sign-out")

            Spacer(minLength: 0)
        }
        .padding(AnimalTokens.spacingLG)
    }
}
