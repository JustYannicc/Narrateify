import SwiftUI

/// The floating reader: section text with the spoken word highlighted, and
/// section-level transport. Same material blob as the synthesis overlay, just
/// taller to fit the text.
struct ReaderOverlayView: View {
    @ObservedObject var session: ReadingSession
    var onClose: () -> Void
    /// Drag anywhere on the card except a button: moved / let go.
    var onDrag: (_ ended: Bool) -> Void = { _ in }

    static let contentWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ReaderTextView(text: session.currentSection?.text ?? "",
                           highlight: session.currentWordRange,
                           dimmed: session.isBuffering)
                .id(session.currentIndex)
                .transition(.opacity)
            controls
        }
        .frame(width: Self.contentWidth)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        // Buttons win over this, so it only kicks in on text and empty space.
        // (isMovableByWindowBackground never fires: SwiftUI eats the clicks.)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) })
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(24)   // breathing room so the shadow isn't clipped
        .animation(.easeInOut(duration: 0.2), value: session.currentIndex)
    }

    // MARK: Header: activity · position · status … close

    private var header: some View {
        HStack(spacing: 8) {
            ReaderEqualizer(active: session.isPlaying && !session.isBuffering)
                .frame(width: 16, height: 11)
            Text(positionLabel)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            status
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Stop reading (esc)")
            .accessibilityLabel("Stop reading")
        }
    }

    private var positionLabel: String {
        session.sections.isEmpty ? "–" : "\(session.currentIndex + 1) / \(session.sections.count)"
    }

    @ViewBuilder private var status: some View {
        if session.isBuffering {
            HStack(spacing: 5) {
                ReaderSpinner().frame(width: 9, height: 9)
                Text("Preparing…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        } else if let error = session.error {
            Label("Skipped a section", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(error)
                .transition(.opacity)
        } else if let note = session.currentSectionNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(note)
                .transition(.opacity)
        }
    }

    // MARK: Controls: transport centered, speed trailing

    private var controls: some View {
        ZStack {
            HStack(spacing: 22) {
                transportButton("backward.end.fill", help: "Previous section (←)") { session.previous() }
                Button { session.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(session.isPlaying ? "Pause (space)" : "Play (space)")
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                transportButton("forward.end.fill", help: "Next section (→)") { session.next() }
                    .disabled(session.currentIndex + 1 >= session.sections.count)
            }
            HStack {
                Spacer()
                speedMenu
            }
        }
    }

    private func transportButton(_ symbol: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(ReadingSession.ratePresets, id: \.self) { preset in
                Button {
                    session.rate = preset
                } label: {
                    if abs(preset - session.rate) < 0.001 {
                        Label(Self.rateLabel(preset), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(preset))
                    }
                }
            }
        } label: {
            Text(Self.rateLabel(session.rate))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.primary.opacity(0.08)))
        .help("Reading speed (↑/↓)")
    }

    static func rateLabel(_ rate: Float) -> String {
        let s = String(format: "%.2f", rate)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return s + "×"
    }
}

/// Small looping arc for "waiting on synthesis".
struct ReaderSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// The synthesis overlay's equalizer, scaled down — four bars bouncing out of
/// phase, frozen while paused or buffering.
struct ReaderEqualizer: View {
    var active: Bool
    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .scaleEffect(x: 1, y: animating ? 1.0 : 0.3, anchor: .center)
                    .animation(
                        active
                            ? .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.11)
                            : .easeOut(duration: 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = active }
        .onChange(of: active) { _, newValue in animating = newValue }
    }
}
