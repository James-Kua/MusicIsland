import AppKit
import SwiftUI

/// The island's SwiftUI layout. Renders compact (artwork + title) and, when
/// expanded, adds controls, a scrubber, and the live lyric.
struct IslandView: View {
    @ObservedObject var model: MusicModel
    weak var windowController: IslandWindowController?
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(spacing: model.isExpanded ? 7 : 10) {
            trackSummary

            if model.isExpanded {
                playbackControls
            }

            if model.isExpanded, !isIdle, model.isShowingQueue {
                upcomingQueuePanel
            } else if model.isExpanded, !isIdle {
                if model.duration > 0 {
                    ScrubberView(
                        elapsed: model.elapsed,
                        duration: model.duration,
                        accent: model.accentColor,
                        onSeek: model.seek(to:)
                    )
                }

                VStack(spacing: 4) {
                    contextLyricLine(
                        displayLyric,
                        position: .current,
                        loading: model.isLoadingLyrics
                    )

                    if model.translatedLyric.hasReadableContent {
                        contextLyricLine(model.translatedLyric, position: .translation)
                    }

                    contextLyricLine(model.nextLyric, position: .surrounding)
                        .padding(.top, model.translatedLyric.hasReadableContent ? 5 : 0)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, model.isExpanded ? 18 : 16)
        .padding(.vertical, model.isExpanded ? 14 : 10)
        .frame(
            width: model.isExpanded ? 520 : 310,
            height: model.isExpanded ? (model.isShowingQueue ? 390 : 220) : 56
        )
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

            if model.isExpanded {
                utilityControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var utilityControls: some View {
        HStack(spacing: 8) {
            IslandIconControl(
                systemName: "list.bullet",
                isActive: model.isShowingQueue,
                accessibilityLabel: model.isShowingQueue ? "Hide Up Next" : "Show Up Next",
                action: { windowController?.toggleUpcomingQueue() }
            )
            IslandIconControl(systemName: "music.note", action: model.openNetEaseMusic)
            IslandIconControl(systemName: "gearshape.fill", action: onOpenPreferences)
        }
        .opacity(0.78)
    }

    private var playbackControls: some View {
        HStack(spacing: 18) {
            IslandIconControl(systemName: "backward.fill", action: model.previousTrack)
            IslandIconControl(systemName: model.track.isPlaying ? "pause.fill" : "play.fill", action: model.togglePlayPause)
            IslandIconControl(systemName: "forward.fill", action: model.nextTrack)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    private var upcomingQueuePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Up Next")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if let source = queueSource {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.accentColor.opacity(0.95))
                            .frame(width: 5, height: 5)
                        Text(source)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(.white.opacity(0.08), in: Capsule())
                }

                Button(action: model.refreshUpcomingQueue) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh Up Next")
            }

            queueContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .layoutPriority(1)
    }

    private var queueSource: String? {
        guard case let .loaded(source, _) = model.upcomingQueue else { return nil }
        return source
    }

    @ViewBuilder
    private var queueContent: some View {
        switch model.upcomingQueue {
        case .idle, .loading:
            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.1))
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 5) {
                            Capsule()
                                .fill(.white.opacity(0.12))
                                .frame(width: index.isMultiple(of: 2) ? 176 : 218, height: 7)
                            Capsule()
                                .fill(.white.opacity(0.07))
                                .frame(width: 104, height: 5)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
            .shimmering(active: true)

        case let .loaded(_, items):
            VStack(spacing: 6) {
                ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 11) {
                        queueArtwork(for: item, isNext: index == 0)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: index == 0 ? .semibold : .medium))
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.46))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if index == 0 {
                            Text("Next")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.52))
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.white.opacity(index == 0 ? 0.095 : 0.052))
                    )
                    .overlay {
                        if index == 0 {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(model.accentColor.opacity(0.32), lineWidth: 1)
                        }
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))

        case let .unavailable(message):
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.07))
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(width: 44, height: 44)

                VStack(spacing: 4) {
                    Text("Nothing queued yet")
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 310)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func queueArtwork(for item: UpcomingQueueItem, isNext: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: item.artworkURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    queueArtworkPlaceholder
                        .shimmering(active: true)
                case .failure:
                    queueArtworkPlaceholder
                @unknown default:
                    queueArtworkPlaceholder
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            }

            if isNext {
                Circle()
                    .fill(model.accentColor)
                    .frame(width: 13, height: 13)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 0.5)
                    }
                    .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 34, height: 34)
    }

    private var queueArtworkPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [model.accentColor.opacity(0.46), .white.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private enum LyricPosition {
        case surrounding
        case current
        case translation

        var size: CGFloat {
            switch self {
            case .surrounding: 11
            case .current: 14
            case .translation: 11
            }
        }

        var weight: Font.Weight {
            self == .current ? .semibold : .medium
        }

        var opacity: Double {
            switch self {
            case .surrounding: 0.38
            case .current: 0.96
            case .translation: 0.62
            }
        }
    }

    /// A cross-fading, marquee-scrolling line in the expanded lyric context.
    private func contextLyricLine(
        _ text: String,
        position: LyricPosition,
        loading: Bool = false
    ) -> some View {
        ZStack {
            MarqueeText(
                text: text,
                font: .system(size: position.size, weight: position.weight),
                color: .white.opacity(position.opacity),
                alignment: .center
            )
            .id(text)
            .transition(.opacity)
        }
        .frame(height: position == .current ? 18 : 14)
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
