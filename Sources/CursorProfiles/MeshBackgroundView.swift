import SwiftUI

/// A slow-drifting, blurred color mesh — the same idea as the website's
/// hero background, brought into the native window. Positions are derived
/// from the current time via TimelineView, so the motion is continuous and
/// costs nothing to keep "animating" (no timers, no state to invalidate).
struct MeshBackgroundView: View {
    private struct Blob {
        let color: Color
        let baseX: CGFloat   // 0...1 fraction of width
        let baseY: CGFloat   // 0...1 fraction of height
        let radius: CGFloat
        let speed: Double
        let phase: Double
    }

    private let blobs: [Blob] = [
        .init(color: Color(hex: "#6366F1") ?? .indigo, baseX: 0.10, baseY: 0.08, radius: 260, speed: 0.055, phase: 0.0),
        .init(color: Color(hex: "#D946EF") ?? .pink,   baseX: 0.88, baseY: 0.16, radius: 220, speed: 0.048, phase: 1.7),
        .init(color: Color(hex: "#F97316") ?? .orange, baseX: 0.28, baseY: 0.90, radius: 210, speed: 0.042, phase: 3.1),
        .init(color: Color(hex: "#0EA5E9") ?? .cyan,   baseX: 0.82, baseY: 0.86, radius: 200, speed: 0.05,  phase: 4.6),
        .init(color: Color(hex: "#84CC16") ?? .green,  baseX: 0.55, baseY: 0.40, radius: 170, speed: 0.065, phase: 5.9),
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Color(nsColor: .windowBackgroundColor)

                    ZStack {
                        ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                            Circle()
                                .fill(blob.color.opacity(0.32))
                                .frame(width: blob.radius * 2, height: blob.radius * 2)
                                .position(
                                    x: geo.size.width * blob.baseX + sin(t * blob.speed + blob.phase) * 70,
                                    y: geo.size.height * blob.baseY + cos(t * blob.speed * 0.82 + blob.phase) * 55
                                )
                        }
                    }
                    .blur(radius: 80)
                    .drawingGroup()
                }
            }
        }
        .ignoresSafeArea()
    }
}
