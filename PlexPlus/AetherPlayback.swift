import SwiftUI
import Combine
import AetherEngine

/// Draws the Aether engine's decoded subtitle cues over the video surface.
///
/// The engine decodes every subtitle format (SRT/ASS text, PGS/DVB bitmaps,
/// external files) into a published `[SubtitleCue]` list but renders nothing
/// itself - the host draws the overlay. Text cues are shown lower-center;
/// bitmap cues are placed using their normalized geometry against the frame.
struct AetherSubtitleOverlay: View {
    let engine: AetherEngine

    @State private var cues: [SubtitleCue] = []
    @State private var sourceTime: Double = 0

    /// Cues whose window contains the source PTS of the displayed frame
    /// (`clock.sourceTime` is the axis subtitles are timed against).
    private var activeCues: [SubtitleCue] {
        cues.filter { $0.startTime <= sourceTime && sourceTime < $0.endTime }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Bitmap cues (PGS/DVB/DVD) carry their own geometry.
                ForEach(activeCues.filter { $0.text == nil }) { cue in
                    bitmapCue(cue, in: geo.size)
                }
                // Text cues stack lower-center.
                let textLines = activeCues.compactMap { $0.text }.filter { !$0.isEmpty }
                if !textLines.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(textLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: max(16, geo.size.height * 0.032), weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .frame(maxWidth: geo.size.width * 0.9)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.9)
                }
            }
        }
        .allowsHitTesting(false)
        .onReceive(engine.$subtitleCues) { cues = $0 }
        .onReceive(engine.clock.$sourceTime) { sourceTime = $0 }
    }

    @ViewBuilder
    private func bitmapCue(_ cue: SubtitleCue, in size: CGSize) -> some View {
        if case .image(let image) = cue.body {
            let rect = CGRect(x: image.position.origin.x * size.width,
                              y: image.position.origin.y * size.height,
                              width: image.position.width * size.width,
                              height: image.position.height * size.height)
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)
        }
    }
}
