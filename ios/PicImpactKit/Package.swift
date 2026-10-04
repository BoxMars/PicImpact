// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicImpactKit",
    // 同时支持 iOS（产品目标）与 macOS（让 swift test 能在 Mac 上直接跑，
    // 无需启动模拟器，迭代快得多）。需要 iOS 专有 API 时用 #if os(iOS) 隔开。
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PicImpactKit", targets: ["PicImpactKit"])
    ],
    targets: [
        .target(name: "PicImpactKit"),
        .testTarget(
            name: "PicImpactKitTests",
            dependencies: ["PicImpactKit"],
            // animal-tokens.json 由 node_modules/animal-island-ui/dist/index.css 直接生成，
            // 是 T2「48 条令牌逐值对照」的基准
            resources: [.copy("Fixtures")]
        )
    ]
)
