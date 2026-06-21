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

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeTextSizeKey.self, value: proxy.size)
                }
            )
            .offset(x: isOverflowing && animate ? -overflow : 0)
            .frame(maxWidth: .infinity, alignment: isOverflowing ? .leading : alignment)
            .frame(height: textSize.height > 0 ? textSize.height : nil)
            .clipped()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(MarqueeTextSizeKey.self) { textSize = $0 }
            .onPreferenceChange(MarqueeWidthKey.self) { containerWidth = $0 }
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

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
