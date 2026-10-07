import Foundation
import os

/// 网络与凭证相关的诊断日志。
///
/// ## 为什么必须有
/// 真机上出现过"登录之后管理页是空的、界面什么都不说"的情况：请求到底发没发出去、
/// 服务端返回的是 401 还是别的、会话有没有带上 —— 这些问题**只靠看界面无法判断**，
/// 而每一次都靠猜都会浪费一轮来回。所以这里把关键事实写进系统日志，
/// 用 `xcrun devicectl device process launch --console` 就能直接看到。
///
/// ## 绝不打印凭证
/// 只记录"有没有带 cookie"（布尔）、以及 cookie 的**名字**与过期状态，不记录值。
public enum APILog {

    private static let logger = Logger(subsystem: "dev.boxz.felina", category: "api")

    /// 一次请求的结果：方法、URL（去掉查询串里的敏感值不需要，这里原样）、状态码
    public static func request(_ method: String, _ url: String, status: Int, attachedSession: Bool) {
        logger.notice("req \(method, privacy: .public) \(url, privacy: .public) -> \(status) session=\(attachedSession)")
    }

    public static func transportError(_ method: String, _ url: String, _ detail: String) {
        logger.error("req \(method, privacy: .public) \(url, privacy: .public) -> transport error: \(detail, privacy: .public)")
    }

    /// 凭证层：只记事实，不记值
    public static func credentials(_ message: String) {
        logger.notice("cred \(message, privacy: .public)")
    }
}
