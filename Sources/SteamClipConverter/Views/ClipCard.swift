import SwiftUI

/// A clip tile. Moving the pointer across the thumbnail scrubs the recording:
/// each position assembles only the DASH segment under the cursor, so scrubbing
/// a 4K clip reads a few MB rather than the whole file.
struct ClipCard: View {
    let clip: Clip
    let isSelected: Bool
    /// Non-nil once this recording has been exported. The card stays in place and
    /// is marked -- hiding it would imply the original was consumed or removed.
    let conversion: ConversionRecord?
    let onToggle: () -> Void

    private var isConverted: Bool { conversion != nil }

    @State private var image: NSImage?
    @State private var scrubFraction: Double?
    @State private var scrubTask: Task<Void, Never>?
    @State private var isHovering = false

    private var aspect: CGFloat {
        guard let p = clip.probe, p.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(p.width) / CGFloat(p.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(clip.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if isConverted {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Label(clip.dateLabel, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(clip.durationLabel)
                    Text("·")
                    Text(clip.resolutionLabel)
                    Text("·")
                    Text(clip.sizeLabel)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if let conversion {
                    Text("\(conversion.label) · \(conversion.format)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .task(id: clip.id) {
            image = await MediaProbe.shared.poster(for: clip)
        }
    }

    private var thumbnail: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isConverted && !isHovering ? 0.45 : 1)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isHovering, let scrubFraction {
                    // Scrub position indicator
                    GeometryReader { inner in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .offset(x: inner.size.width * scrubFraction)
                    }
                    .allowsHitTesting(false)
                }

                HStack(spacing: 4) {
                    if let p = clip.probe, p.isHEVC {
                        Badge(text: "HEVC")
                    }
                    if isHovering, let scrubFraction {
                        Badge(text: timeLabel(scrubFraction * clip.duration))
                    }
                }
                .padding(6)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                } else if isConverted {
                    Text("CONVERTED")
                        .font(.caption2.weight(.bold))
                        .kerning(0.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    isHovering = true
                    let fraction = min(max(point.x / max(geo.size.width, 1), 0), 1)
                    scrubFraction = fraction
                    scheduleScrub(to: fraction * clip.duration)
                case .ended:
                    isHovering = false
                    scrubFraction = nil
                    scrubTask?.cancel()
                    Task { image = await MediaProbe.shared.poster(for: clip) }
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    /// Debounced: the pointer crosses many pixels per segment, and only the
    /// segment under the cursor is worth assembling.
    private func scheduleScrub(to time: Double) {
        scrubTask?.cancel()
        scrubTask = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            if let frame = await MediaProbe.shared.frame(for: clip, at: time) {
                guard !Task.isCancelled else { return }
                image = frame
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }
}
