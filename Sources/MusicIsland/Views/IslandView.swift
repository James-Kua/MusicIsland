import AppKit
import SwiftUI

/// The island's SwiftUI layout. Renders compact (artwork + title) and, when
/// expanded, adds controls, a scrubber, and the live lyric.
struct IslandView: View {
    @ObservedObject var model: MusicModel
    weak var windowController: IslandWindowController?

    var body: some View {
        VStack(spacing: model.isExpanded ? 7 : 10) {
            trackSummary

            if model.isExpanded {
                playbackControls
            }

            if model.isExpanded, !isIdle {
                if model.duration > 0 {
                    ScrubberView(
                        elapsed: model.elapsed,
                        duration: model.duration,
                        accent: model.accentColor,
                        onSeek: model.seek(to:)
                    )
                }

                VStack(spacing: 3) {
                    lyricLine(
                        displayLyric,
                        size: 13,
                        opacity: 0.92,
                        loading: model.isLoadingLyrics
                    )

                    if model.translatedLyric.hasReadableContent {
                        lyricLine(model.translatedLyric, size: 12, opacity: 0.64, loading: false)
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, model.isExpanded ? 18 : 16)
        .padding(.vertical, model.isExpanded ? 14 : 10)
        .frame(width: model.isExpanded ? 520 : 310, height: model.isExpanded ? 184 : 56)
        .background(islandBackground)
        .overlay(
            RoundedRectangle(cornerRadius: model.isExpanded ? 28 : 24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .onHover { hovering in
            setHovering(hovering)
        }
    }

    private var artistText: String {
        model.track.artist.isEmpty ? "Unknown artist" : model.track.artist
    }

    private var isIdle: Bool {
        model.track == Track.empty
    }

    /// Blanks out lyric lines that are only dashes/symbols so they don't render
    /// as a stray "long dash"; readable text and placeholders pass through.
    private var displayLyric: String {
        model.lyric.hasReadableContent ? model.lyric : ""
    }

    private var cornerRadius: CGFloat {
        model.isExpanded ? 28 : 24
    }

    private var islandBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(.black)
            shape.fill(
                LinearGradient(
                    colors: [model.accentColor.opacity(0.55), model.accentColor.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var trackSummary: some View {
        HStack(spacing: 10) {
            ArtworkView(image: model.coverImage, isPlaying: model.track.isPlaying)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: model.track.title,
                    font: .system(size: model.isExpanded ? 15 : 13, weight: .semibold),
                    color: .white
                )
                MarqueeText(
                    text: artistText,
                    font: .system(size: 11, weight: .medium),
                    color: .white.opacity(0.68)
                )
                if model.isExpanded, !model.track.album.isEmpty {
                    MarqueeText(
                        text: model.track.album,
                        font: .system(size: 10, weight: .medium),
                        color: .white.opacity(0.5)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackControls: some View {
        HStack(spacing: 18) {
            IslandIconControl(systemName: "backward.fill", action: model.previousTrack)
            IslandIconControl(systemName: model.track.isPlaying ? "pause.fill" : "play.fill", action: model.togglePlayPause)
            IslandIconControl(systemName: "forward.fill", action: model.nextTrack)
            IslandIconControl(systemName: "music.note", action: model.openNetEaseMusic)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    /// A cross-fading, marquee-scrolling lyric line.
    private func lyricLine(_ text: String, size: CGFloat, opacity: Double, loading: Bool) -> some View {
        ZStack {
            MarqueeText(
                text: text,
                font: .system(size: size, weight: .medium),
                color: .white.opacity(opacity),
                alignment: .center
            )
            .id(text)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.28), value: text)
        .shimmering(active: loading)
    }

    private func setHovering(_ hovering: Bool) {
        if hovering {
            windowController?.cancelCollapse()
        } else {
            windowController?.scheduleCollapse()
        }
    }
}
