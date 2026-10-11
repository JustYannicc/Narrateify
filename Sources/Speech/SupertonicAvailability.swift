import Foundation

extension SupertonicEngine {
    /// Routing skips Supertonic until a complete model is on disk.
    var unavailableReason: String? {
        SupertonicBackend.installed(at: modelDirectory) == nil ? "Model not downloaded — see Engines" : nil
    }
}
