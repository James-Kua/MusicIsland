import AppKit
import SwiftUI

/// The island's SwiftUI layout. Renders compact (artwork + title) and, when
/// expanded, adds controls, a scrubber, and the live lyric.
struct IslandView: View {
    @ObservedObject var model: MusicModel
    weak var windowController: IslandWindowController?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(image: model.coverImage, isPlaying: model.track.isPlaying)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.track.title)
                        .font(.system(size: model.isExpanded ? 15 : 13, weight: .semibold))
                        .lineLimit(1)
                    Text(artistText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if model.isExpanded, !model.track.album.isEmpty {
                        Text(model.track.album)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.78))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if model.isExpanded {
                    IslandIconControl(systemName: "backward.fill", action: model.previousTrack)
                    IslandIconControl(systemName: model.track.isPlaying ? "pause.fill" : "play.fill", action: model.togglePlayPause)
                    IslandIconControl(systemName: "forward.fill", action: model.nextTrack)
                    IslandIconControl(systemName: "music.note", action: model.openNetEaseMusic)
                }
            }

            if model.isExpanded {
                ScrubberView(
                    elapsed: model.elapsed,
                    duration: model.duration,
                    onSeek: model.seek(to:)
                )

                VStack(spacing: 3) {
                    Text(model.lyric)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    if !model.translatedLyric.isEmpty {
                        Text(model.translatedLyric)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.64))
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, model.isExpanded ? 18 : 16)
        .padding(.vertical, model.isExpanded ? 14 : 10)
        .frame(width: model.isExpanded ? 520 : 310, height: model.isExpanded ? 154 : 56)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: model.isExpanded ? 28 : 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: model.isExpanded ? 28 : 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.isExpanded)
        .onHover { hovering in
            setHovering(hovering)
        }
    }

    private var artistText: String {
        model.track.artist.isEmpty ? "Unknown artist" : model.track.artist
    }

    private func setHovering(_ hovering: Bool) {
        if hovering {
            windowController?.cancelCollapse()
        } else {
            windowController?.scheduleCollapse()
        }
    }
}
