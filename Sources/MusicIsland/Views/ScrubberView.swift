import SwiftUI

/// A seek bar with drag-to-scrub. Shows a live preview position while dragging
/// and reports the final position via `onSeek`.
struct ScrubberView: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    var accent: Color = .white
    let onSeek: (TimeInterval) -> Void

    @State private var previewElapsed: TimeInterval?

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let activeElapsed = previewElapsed ?? elapsed
                let progress = duration > 0 ? min(max(activeElapsed / duration, 0), 1) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 5)
                    Capsule()
                        .fill(accent)
                        .brightness(0.18)
                        .saturation(1.2)
                        .frame(width: width * progress, height: 5)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: max(0, min(width - 11, width * progress - 5.5)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            previewElapsed = time(for: value.location.x, width: width)
                        }
                        .onEnded { value in
                            let target = time(for: value.location.x, width: width)
                            previewElapsed = nil
                            onSeek(target)
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(formatTime(previewElapsed ?? elapsed))
                Spacer()
                Text(duration > 0 ? formatTime(duration) : "--:--")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.62))
        }
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard duration > 0 else { return 0 }
        let ratio = min(max(x / max(width, 1), 0), 1)
        return duration * ratio
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
