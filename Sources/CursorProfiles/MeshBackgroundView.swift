import SwiftUI

/// Ambient background mesh — now using PrismTheme colors
struct MeshBackgroundView: View {
    private struct Blob {
        let color: Color
        let baseX: CGFloat
        let baseY: CGFloat
        let radius: CGFloat
    }

    private let blobs: [Blob] = [
        .init(color: PrismTheme.Colors.cyan,   baseX: 0.10, baseY: 0.08, radius: 260),
        .init(color: PrismTheme.Colors.purple, baseX: 0.88, baseY: 0.16, radius: 220),
        .init(color: PrismTheme.Colors.orange, baseX: 0.28, baseY: 0.90, radius: 210),
        .init(color: PrismTheme.Colors.cyan,   baseX: 0.82, baseY: 0.86, radius: 200),
        .init(color: PrismTheme.Colors.emerald, baseX: 0.55, baseY: 0.40, radius: 170),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PrismTheme.Colors.bg

                ZStack {
                    ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                        Circle()
                            .fill(blob.color.opacity(0.12))
                            .frame(width: blob.radius * 2, height: blob.radius * 2)
                            .position(x: geo.size.width * blob.baseX, y: geo.size.height * blob.baseY)
                    }
                }
                .blur(radius: 80)
                .drawingGroup()
            }
        }
        .ignoresSafeArea()
    }
}
