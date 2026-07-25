import AppKit
import SwiftUI

/// Album artwork thumbnail with a small playing/paused status dot.
struct ArtworkView: View {
    let image: NSImage?
    let isPlaying: Bool
    /// The island keeps its view tree alive while hidden, and an animation
    /// running in an off-screen window still drives the display cycle — so the
    /// placeholder only shimmers while someone can see it.
    var isVisible: Bool = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.12))
                        .shimmering(active: isVisible)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )

            Circle()
                .fill(isPlaying ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.black.opacity(0.75), lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
        .frame(width: 42, height: 42)
    }
}
