import Foundation

extension SupertonicEngine {
    /// Routing skips Supertonic until a complete model is on disk.
    var unavailableReason: String? {
        SupertonicBackend.installed(at: modelDirectory) == nil ? "Model not downloaded — see Engines" : nil
    }
}

extension SupertonicEngine {
    /// Cold-load the model while the selection is being captured.
    func prewarm() {
        guard !isLoaded, unavailableReason == nil else { return }
        Task { try? await preload() }
    }
}
