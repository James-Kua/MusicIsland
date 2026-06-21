import SwiftUI

/// A moving highlight masked to the modified view, used as a loading state for
/// lyrics and missing artwork.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    GeometryReader { proxy in
                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .white.opacity(0.7), .clear]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 1.3)
                        .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
