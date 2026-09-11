import SwiftUI

/// A static, blurred color mesh behind the window — same palette as the
/// website's hero, but fixed in place (no motion).
struct MeshBackgroundView: View {
    private struct Blob {
        let color: Color
        let baseX: CGFloat   // 0...1 fraction of width
        let baseY: CGFloat   // 0...1 fraction of height
        let radius: CGFloat
    }

    private let blobs: [Blob] = [
        .init(color: Color(hex: "#6366F1") ?? .indigo, baseX: 0.10, baseY: 0.08, radius: 260),
        .init(color: Color(hex: "#D946EF") ?? .pink,   baseX: 0.88, baseY: 0.16, radius: 220),
        .init(color: Color(hex: "#F97316") ?? .orange, baseX: 0.28, baseY: 0.90, radius: 210),
        .init(color: Color(hex: "#0EA5E9") ?? .cyan,   baseX: 0.82, baseY: 0.86, radius: 200),
        .init(color: Color(hex: "#84CC16") ?? .green,  baseX: 0.55, baseY: 0.40, radius: 170),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                ZStack {
                    ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                        Circle()
                            .fill(blob.color.opacity(0.32))
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
