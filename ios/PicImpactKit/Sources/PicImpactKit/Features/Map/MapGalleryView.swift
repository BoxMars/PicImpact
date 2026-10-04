import MapKit
import SwiftUI

/// 地图页：展示有经纬度的照片。
///
/// Web 端用 maplibre-gl；iOS 用 MapKit（原生、零成本、体验更好）。
/// 两者底图不同，属于设计文档 §3.2 里"结果一致、实现必然不同"的范畴。
///
/// 注意 Web 端踩过的坑：maplibre 的 `move` 事件每帧触发，早期直接 `setBounds + setZoom`
/// 导致拖动卡顿。MapKit 没有这个问题，但**不要**在 `onCameraChange` 里做同步重计算。
public struct MapGalleryView: View {
    public struct LocatedImage: Identifiable, Equatable, Sendable {
        public let image: ImageDTO
        public let coordinate: CLLocationCoordinate2D

        public var id: String { image.id }

        public static func == (lhs: LocatedImage, rhs: LocatedImage) -> Bool {
            lhs.image.id == rhs.image.id
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    private let items: [LocatedImage]
    private let onSelect: (ImageDTO) -> Void
    @State private var position: MapCameraPosition

    public init(items: [ImageDTO], onSelect: @escaping (ImageDTO) -> Void = { _ in }) {
        let located = Self.located(from: items)
        self.items = located
        self.onSelect = onSelect
        _position = State(initialValue: Self.initialPosition(for: located))
    }

    public var body: some View {
        Map(position: $position) {
            ForEach(items) { item in
                Annotation(
                    item.image.title.isEmpty ? item.image.id : item.image.title,
                    coordinate: item.coordinate
                ) {
                    Button {
                        onSelect(item.image)
                    } label: {
                        AnnotationPin()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard)
    }

    /// 经纬度解析：数据库里是字符串，且缺失时是空串。
    /// **必须与 Web 的 `fetchMapImages` 语义一致**： (0,0) 视为无效。
    static func located(from images: [ImageDTO]) -> [LocatedImage] {
        images.compactMap { image in
            guard let latitude = Double(image.lat), let longitude = Double(image.lon) else { return nil }
            guard latitude != 0 || longitude != 0 else { return nil }
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return LocatedImage(
                image: image,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
    }

    static func initialPosition(for items: [LocatedImage]) -> MapCameraPosition {
        guard !items.isEmpty else {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
                span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
            ))
        }
        guard items.count > 1 else {
            return .region(MKCoordinateRegion(
                center: items[0].coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
        let latitudes = items.map(\.coordinate.latitude)
        let longitudes = items.map(\.coordinate.longitude)
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // 留 40% 余量，避免点贴在边缘
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.01, (maxLon - minLon) * 1.4)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

/// 地图上的照片标记：岛屿卡的小尺寸化（保持同一套视觉语言）
private struct AnnotationPin: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .circular)
            .fill(AnimalSignatures.cardPaper)
            .frame(width: 26, height: 26)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .circular)
                    .strokeBorder(AnimalSignatures.cardBorder, lineWidth: 2)
            }
            .shadow(color: AnimalSignatures.cardShadowHard, radius: 0, x: 0, y: 2)
    }
}
