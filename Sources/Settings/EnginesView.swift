import SwiftUI

/// Settings → Engines: VoiceInk-style cards (speed / quality / RAM / disk /
/// privacy), Supertonic download management, and an on-device benchmark that
/// measures real time-to-audio for each engine in your languages.
struct EnginesView: View {
    @EnvironmentObject var state: AppState
    @State private var measured: [SpeechEngineKind: String] = [:]
    @State private var measuring = false

    var body: some View {
        Form {
            Section {
                HStack {
                    MemoryLabel()
                    Spacer()
                    Button(measuring ? "Measuring…" : "Measure speed") { measure() }
                        .disabled(measuring)
                }
                Text("Measure runs a sample sentence through each free engine in each of your languages and shows the real time until audio is ready on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(EngineCatalog.cards) { card in
                Section {
                    EngineCardView(card: card, measured: measured[card.kind])
                    if card.kind == .supertonic { SupertonicControls() }
                    if card.kind == .edge { EdgeControls() }
                    if card.kind == .qwen3 { Qwen3Controls(store: state.qwen3) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func measure() {
        measuring = true
        Task {
            for card in EngineCatalog.cards {
                measured[card.kind] = "…"
                measured[card.kind] = await state.narrator.benchmark(card.kind)
            }
            measuring = false
        }
    }
}

private struct EngineCardView: View {
    let card: EngineCard
    let measured: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.kind.label).font(.headline)
                Spacer()
                Text(card.kind.isLocal ? "On-device" : "Online")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(card.kind.isLocal ? Color.green.opacity(0.18) : Color.blue.opacity(0.18)))
            }
            HStack(spacing: 18) {
                RatingBar(label: "Speed", value: card.speed)
                RatingBar(label: "Quality", value: card.quality)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                row("RAM", card.ram)
                row("Disk", card.disk)
                row("Languages", card.languages)
                row("Privacy", card.privacy)
                if let measured { row("Time to audio", measured) }
            }
            .font(.caption)
            Text(card.blurb).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }
}

/// "Speed  ▮▮▮▮▮▮▮▮▯▯ 8/10"
private struct RatingBar: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < value ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: 7, height: 10)
                }
            }
            Text("\(value)/10").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) out of 10")
    }
}

private struct SupertonicControls: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let store = state.supertonic
        HStack {
            switch store.state {
            case .notInstalled:
                Text("Not downloaded").foregroundStyle(.secondary)
                Spacer()
                Button("Download (\(MemoryFootprint.format(SupertonicModelStore.downloadSize)))") { store.install() }
            case .downloading(let progress):
                if store.installedBackend != nil { Text("Upgrading to Core ML").foregroundStyle(.secondary) }
                ProgressView(value: progress).frame(maxWidth: 220)
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancel() }
            case .installed:
                Label(supertonicStatus, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if store.upgradeAvailable {
                    Button("Upgrade (faster)") { store.upgrade() }
                        .help(store.upgradeError ?? "Download the Core ML decoder: ~6× faster, ~¼ the memory")
                }
                Spacer()
                Text(MemoryFootprint.format(store.diskUsage)).foregroundStyle(.secondary)
                Button("Remove", role: .destructive) { removeModel() }
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(2)
                Spacer()
                Button("Retry") { store.install() }
            }
        }
    }
}

private extension SupertonicControls {
    /// Unload first (on the engine's queue) so nothing is reading the files
    /// while they're deleted.
    func removeModel() {
        Task {
            await state.supertonicEngine.unloadAndWait()
            do { try state.supertonic.uninstall() } catch { state.status = error.localizedDescription }
        }
    }

    var supertonicStatus: String {
        let backend = state.supertonic.installedBackend == .coreML ? "Core ML" : "ONNX"
        switch state.supertonicEngine.loadedBackend {
        case .coreML?: return "Loaded · Core ML"
        case .onnx?:   return "Loaded · ONNX"
        case nil:      return "Downloaded (\(backend)) · loads on first use"
        }
    }
}

private struct Qwen3Controls: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: Qwen3ModelStore

    var body: some View {
        HStack {
            if let why = Qwen3ModelStore.unsupportedReason {
                Text(why).foregroundStyle(.secondary)
            } else {
                switch store.state {
                case .notInstalled:
                    Text("Not downloaded").foregroundStyle(.secondary)
                    Spacer()
                    Button("Download (\(MemoryFootprint.format(Qwen3ModelStore.downloadSize)))") { install() }
                case .downloading(let progress, let message):
                    ProgressView(value: progress).frame(maxWidth: 220)
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .installed:
                    // The helper starts and quits on its own; re-check every few seconds.
                    TimelineView(.periodic(from: .now, by: 3)) { _ in
                        Label(state.qwen3Engine.isLoaded ? "Loaded" : "Downloaded · loads when a call asks for it",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(MemoryFootprint.format(store.diskUsage)).foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) {
                        Task { try? await state.uninstallModel(for: .qwen3) }
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Retry") { install() }
                }
            }
        }
    }

    private func install() {
        Task { try? await store.install() }
    }
}

private struct EdgeControls: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            if state.narrator.isBenched(.edge) {
                Label("Unreachable — using fallbacks for now", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Retry now") { state.narrator.retryEngines() }
            } else {
                Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
            }
        }
    }
}

/// Polls the footprint in its own view so the rest of the tab doesn't redraw.
private struct MemoryLabel: View {
    @State private var text = MemoryFootprint.format(MemoryFootprint.current())

    var body: some View {
        Text("Narrateify is using \(text) of memory")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    let next = MemoryFootprint.format(MemoryFootprint.current())
                    if next != text { text = next }
                }
            }
    }
}

/// The app's physical memory footprint — what Activity Monitor's "Memory"
/// column shows.
enum MemoryFootprint {
    static func current() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
