import CoreGraphics
import Foundation
import SwiftUI

/// ACNH 图标的 SVG 渲染器（极简，只覆盖这些素材实际用到的子集）。
///
/// ## 为什么不用 asset catalog
/// 最初把 SVG 放进 `Assets.xcassets`，但 `swift build`（macOS）**不会调用 actool** ——
/// 实测 `swift build -v` 里 actool 出现 0 次，资源目录只是被原样拷贝，
/// 于是 `Bundle.module` 里没有编译后的图像、`Image(name:)` 也取不到东西。
/// 只有经 Xcode 构建 iOS 时才会跑 actool（实测产物里有 127KB 的 Assets.car）。
/// 结果是：**iOS 上或许能显示，但本地完全无法验证**，而这个位置一旦出错是静默的
/// （界面上只是少一块，不报错）。所以改成自己渲染矢量路径 —— 两端行为一致、可测。
///
/// ## 覆盖范围（由 `scripts/ios-icons.mjs` 提取的 8 个图标实测得出）
/// - 元素：`path` / `rect` / `circle` / `ellipse`
/// - 路径命令：`M L H V C Z`（大小写即绝对/相对）。这些素材**不含 arc 与二次曲线**
/// - 属性：`fill`（`#rrggbb` / `none`）、`fill-rule`（含 `evenodd`，必须支持，
///   否则图标上的镂空会被实心填掉）
///
/// 不追求通用 SVG 支持：遇到不认识的命令就跳过该条，而不是崩溃。
public enum SVGIcon {

    public struct Shape: Sendable {
        public let path: Path
        public let color: Color
        /// `fill-rule: evenodd` —— 图标里的镂空全靠它
        public let evenOdd: Bool
    }

    public struct Icon: Sendable {
        public let viewBox: CGRect
        public let shapes: [Shape]
    }

    // MARK: - 解析

    /// 解析 SVG 文本。失败返回 nil（调用方回退为不渲染，而不是崩溃）。
    public static func parse(_ source: String) -> Icon? {
        let parser = Parser(source: source)
        return parser.parse()
    }

    // MARK: - 路径数据

    /// 解析 `d` 属性。只支持 M/L/H/V/C/Z（绝对与相对）。
    static func path(from data: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var index = data.startIndex
        var command: Character = "M"
        var hasPendingCommand = false

        func nextNumber() -> CGFloat? {
            // 跳过分隔符
            while index < data.endIndex, data[index] == " " || data[index] == "," || data[index] == "\n" {
                index = data.index(after: index)
            }
            guard index < data.endIndex else { return nil }
            // 不该在这里遇到命令字母
            if data[index].isLetter { return nil }
            let start = index
            while index < data.endIndex {
                let c = data[index]
                if c.isNumber || c == "." || c == "-" || c == "+" || c == "e" || c == "E" {
                    // '-' 出现在数字中间（如 1e-5）应继续；出现在开头则是新数字
                    if (c == "-" || c == "+"), index != start {
                        // 指数部分允许
                        let previous = data[data.index(before: index)]
                        if previous != "e", previous != "E" { break }
                    }
                    index = data.index(after: index)
                } else {
                    break
                }
            }
            return CGFloat(Double(String(data[start..<index])) ?? 0)
        }

        func skipSeparators() {
            while index < data.endIndex, data[index] == " " || data[index] == "," || data[index] == "\n" {
                index = data.index(after: index)
            }
        }

        while index < data.endIndex {
            skipSeparators()
            guard index < data.endIndex else { break }

            if data[index].isLetter {
                command = data[index]
                index = data.index(after: index)
                hasPendingCommand = false
            } else if hasPendingCommand {
                // 隐式重复：M 之后的坐标对按 L 处理，其余命令沿用上一个命令
                command = (command == "M") ? "L" : (command == "m") ? "l" : command
            } else {
                break
            }

            let isRelative = command.isLowercase
            let upper = Character(command.uppercased())

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch upper {
            case "M":
                guard let x = nextNumber(), let y = nextNumber() else { break }
                let target = point(x, y)
                path.move(to: target)
                current = target
                subpathStart = target
            case "L":
                guard let x = nextNumber(), let y = nextNumber() else { break }
                let target = point(x, y)
                path.addLine(to: target)
                current = target
            case "H":
                guard let x = nextNumber() else { break }
                let target = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
                path.addLine(to: target)
                current = target
            case "V":
                guard let y = nextNumber() else { break }
                let target = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
                path.addLine(to: target)
                current = target
            case "C":
                guard let x1 = nextNumber(), let y1 = nextNumber(),
                      let x2 = nextNumber(), let y2 = nextNumber(),
                      let x = nextNumber(), let y = nextNumber() else { break }
                let c1 = point(x1, y1)
                let c2 = point(x2, y2)
                let target = point(x, y)
                path.addCurve(to: target, control1: c1, control2: c2)
                current = target
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                // 不认识的命令：跳过（宁可少画，也不要整图崩掉）
                break
            }
            hasPendingCommand = true
        }

        return path
    }

    // MARK: - XML 解析

    private final class Parser: NSObject, XMLParserDelegate {
        private let source: String
        private var viewBox: CGRect = .zero
        private var shapes: [Shape] = []
        private var failed = false

        init(source: String) {
            self.source = source
        }

        func parse() -> Icon? {
            guard let data = source.data(using: .utf8) else { return nil }
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            guard !failed, !shapes.isEmpty else { return nil }
            return Icon(viewBox: viewBox, shapes: shapes)
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "svg":
                viewBox = Self.parseViewBox(attributes["viewBox"])
                    ?? CGRect(
                        x: 0, y: 0,
                        width: Double(attributes["width"] ?? "0") ?? 0,
                        height: Double(attributes["height"] ?? "0") ?? 0
                    )
            case "path":
                guard let d = attributes["d"], !d.isEmpty else { return }
                append(
                    path: path(from: d),
                    fill: attributes["fill"],
                    fillRule: attributes["fill-rule"]
                )
            case "rect":
                let x = Double(attributes["x"] ?? "0") ?? 0
                let y = Double(attributes["y"] ?? "0") ?? 0
                let width = Double(attributes["width"] ?? "0") ?? 0
                let height = Double(attributes["height"] ?? "0") ?? 0
                let radius = Double(attributes["rx"] ?? attributes["ry"] ?? "0") ?? 0
                guard width > 0, height > 0 else { return }
                let rect = CGRect(x: x, y: y, width: width, height: height)
                let path = radius > 0
                    ? Path(roundedRect: rect, cornerRadius: radius)
                    : Path(rect)
                append(path: path, fill: attributes["fill"], fillRule: nil)
            case "circle":
                let cx = Double(attributes["cx"] ?? "0") ?? 0
                let cy = Double(attributes["cy"] ?? "0") ?? 0
                let r = Double(attributes["r"] ?? "0") ?? 0
                guard r > 0 else { return }
                let path = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                append(path: path, fill: attributes["fill"], fillRule: nil)
            case "ellipse":
                let cx = Double(attributes["cx"] ?? "0") ?? 0
                let cy = Double(attributes["cy"] ?? "0") ?? 0
                let rx = Double(attributes["rx"] ?? "0") ?? 0
                let ry = Double(attributes["ry"] ?? "0") ?? 0
                guard rx > 0, ry > 0 else { return }
                let path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                append(path: path, fill: attributes["fill"], fillRule: nil)
            default:
                break
            }
        }

        private func append(path: Path, fill: String?, fillRule: String?) {
            guard let fill, fill != "none" else { return }
            guard let color = Self.parseColor(fill) else { return }
            shapes.append(Shape(path: path, color: color, evenOdd: fillRule == "evenodd"))
        }

        private static func parseViewBox(_ value: String?) -> CGRect? {
            guard let value else { return nil }
            let numbers = value
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            guard numbers.count == 4 else { return nil }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }

        private static func parseColor(_ value: String) -> Color? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            var hex = String(trimmed.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return nil }
            return Color(
                red: Double((number >> 16) & 0xFF) / 255,
                green: Double((number >> 8) & 0xFF) / 255,
                blue: Double(number & 0xFF) / 255
            )
        }
    }
}
