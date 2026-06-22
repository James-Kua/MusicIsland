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

    @State private var textMeasurement = MarqueeTextMeasurement()
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false
    @State private var animationGeneration = 0

    private let overflowTolerance: CGFloat = 6

    private var textSize: CGSize { textMeasurement.size }
    private var overflow: CGFloat { max(0, textSize.width - containerWidth) }
    private var hasCurrentTextMeasurement: Bool { textMeasurement.text == text && textSize.width > 0 }
    private var isMeasured: Bool { hasCurrentTextMeasurement && containerWidth > 0 }
    private var isOverflowing: Bool { isMeasured && overflow > overflowTolerance }
    private var visibleAlignment: Alignment { isOverflowing ? .leading : alignment }

    var body: some View {
        Color.clear
            .overlay(alignment: visibleAlignment) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: isOverflowing && animate ? -overflow : 0)
            }
        .frame(maxWidth: .infinity, alignment: visibleAlignment)
        .frame(height: hasCurrentTextMeasurement ? textSize.height : nil)
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MarqueeContainerWidthKey.self, value: proxy.size.width)
            }
        )
        .background(
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MarqueeTextSizeKey.self,
                            value: MarqueeTextMeasurement(text: text, size: proxy.size)
                        )
                    }
                )
        )
        .onPreferenceChange(MarqueeTextSizeKey.self) { textMeasurement = $0 }
        .onPreferenceChange(MarqueeContainerWidthKey.self) { containerWidth = $0 }
        .onChange(of: text) { _ in restart() }
        .onChange(of: textMeasurement) { _ in restart() }
        .onChange(of: containerWidth) { _ in restart() }
        .onAppear { restart() }
    }

    private func restart() {
        animationGeneration += 1
        let generation = animationGeneration

        var stop = Transaction()
        stop.disablesAnimations = true
        withTransaction(stop) { animate = false }

        guard isOverflowing else { return }
        scheduleScroll(generation: generation)
    }

    private func scheduleScroll(generation: Int) {
        let duration = max(2.0, Double(overflow) / pointsPerSecond)
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
            guard generation == animationGeneration, isOverflowing else { return }
            withAnimation(.easeInOut(duration: duration)) {
                animate = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + startDelay) {
                guard generation == animationGeneration, isOverflowing else { return }

                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { animate = false }

                scheduleScroll(generation: generation)
            }
        }
    }
}

private struct MarqueeTextMeasurement: Equatable {
    var text = ""
    var size: CGSize = .zero
}

private struct MarqueeTextSizeKey: PreferenceKey {
    static var defaultValue = MarqueeTextMeasurement()
    static func reduce(value: inout MarqueeTextMeasurement, nextValue: () -> MarqueeTextMeasurement) {
        value = nextValue()
    }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
