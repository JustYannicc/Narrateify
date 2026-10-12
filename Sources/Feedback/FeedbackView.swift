import SwiftUI

/// One field, Send. Return sends, Shift+Return is a newline, Esc closes.
struct FeedbackView: View {
    let send: (String) async -> FeedbackReporter.Result
    let close: () -> Void

    @State private var message = ""
    @State private var status: (text: String, ok: Bool?)?
    @State private var isSending = false
    @FocusState private var focused: Bool

    private var isEmpty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's wrong, or what would make it better?")
                .font(.headline)
            TextEditor(text: $message)
                .font(.body)
                .focused($focused)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .disabled(isSending || !FeedbackReporter.isConfigured)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit()
                    return .handled
                }
            HStack {
                if let status {
                    Text(status.text)
                        .font(.callout)
                        .foregroundStyle(status.ok == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                } else {
                    Text("Sends recent log lines, your engine settings and the status line along. Never the text you read or your API keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending || isEmpty || !FeedbackReporter.isConfigured)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onExitCommand(perform: close)
        .onAppear {
            if FeedbackReporter.isConfigured {
                focused = true
            } else {
                status = (FeedbackReporter.notConfiguredMessage, false)
            }
        }
    }

    private func submit() {
        guard !isSending, !isEmpty else { return }
        isSending = true
        status = ("Sending…", nil)
        Task {
            switch await send(message) {
            case .notConfigured:
                status = (FeedbackReporter.notConfiguredMessage, false)
                isSending = false
            case .sent:
                status = ("Sent, thanks.", true)
                try? await Task.sleep(for: .seconds(1.2))
                message = ""
                status = nil
                isSending = false
                close()
            }
        }
    }
}

/// The "Send Feedback…" window. Dropped on close, so the next open starts
/// with an empty field.
@MainActor
final class FeedbackWindow: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindow()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = FeedbackView(
            send: { await AppState.shared.sendFeedback($0) },
            close: { [weak self] in self?.window?.close() }
        )
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Send Feedback"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
