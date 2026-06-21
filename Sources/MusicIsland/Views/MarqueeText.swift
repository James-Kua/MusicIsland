import SwiftUI

/// Single-line text that gently scrolls back and forth when it's too wide to
/// fit, and stays statically aligned when it fits. Used for titles, artists,
/// and lyric lines that would otherwise be clipped.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    var alignment: Alignment = .leading
    var startDelay: Double = 1.2
    var pointsPerSecond: Double = 30

    @State private var textSize: CGSize = .zero
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    private var overflow: CGFloat { max(0, textSize.width - containerWidth) }
    private var isOverflowing: Bool { overflow > 1 }
    private var visibleAlignment: Alignment { isOverflowing ? .leading : alignment }

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .overlay(alignment: visibleAlignment) {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: isOverflowing && animate ? -overflow : 0)
                }
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { containerWidth = $0 }
        }
        .frame(maxWidth: .infinity)
        .frame(height: textSize.height > 0 ? textSize.height : nil)
        .clipped()
        .background(
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MarqueeTextSizeKey.self, value: proxy.size)
                    }
                )
        )
        .onPreferenceChange(MarqueeTextSizeKey.self) { textSize = $0 }
        .onChange(of: text) { _ in restart() }
        .onChange(of: isOverflowing) { _ in restart() }
        .onAppear { restart() }
    }

    private func restart() {
        var stop = Transaction()
        stop.disablesAnimations = true
        withTransaction(stop) { animate = false }

        guard isOverflowing else { return }
        let duration = max(2.0, Double(overflow) / pointsPerSecond)
        DispatchQueue.main.async {
            withAnimation(
                .easeInOut(duration: duration).delay(startDelay).repeatForever(autoreverses: true)
            ) {
                animate = true
            }
        }
    }
}

private struct MarqueeTextSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
