import Foundation

/// Synthesis scheduling + caches for a `ReadingSession`. Knows nothing about
/// playback; the session tells it where the playhead is and hears back when a
/// section is ready or failed.
///
/// Latency rules:
/// - The section at the playhead is synthesized immediately, never queued
///   behind a prefetch.
/// - Prefetch starts only once the playhead section is ready, one request at a
///   time, in order, up to `depth` ahead — no request storms.
/// - Synthesized audio is cached for the whole session (going back costs a
///   ~ms decode at most); decoded PCM is kept only near the playhead.
/// - Jobs outside the window are cancelled on a jump; everything on cancelAll().
@MainActor
final class SectionPipeline {
    typealias Synthesize = (ReadingSection) async throws -> SynthesizedSpeech

    let sections: [ReadingSection]
    let depth: Int
    var onReady: ((Int) -> Void)?
    var onFailed: ((Int, Error) -> Void)?

    private let synthesize: Synthesize
    private var audio: [Int: SynthesizedSpeech] = [:]
    private var decoded: [Int: DecodedSection] = [:]
    private var failed: Set<Int> = []
    private var jobs: [Int: Job] = [:]
    private var nextJobID = 0
    private var playhead: Int?          // nil = inactive, schedule nothing

    private struct Job {
        let id: Int
        let task: Task<Void, Never>
    }

    init(sections: [ReadingSection], depth: Int, synthesize: @escaping Synthesize) {
        self.sections = sections
        self.depth = depth
        self.synthesize = synthesize
    }

    // MARK: Queries

    func decodedSection(at i: Int) -> DecodedSection? { decoded[i] }
    func speech(at i: Int) -> SynthesizedSpeech? { audio[i] }
    func hasFailed(_ i: Int) -> Bool { failed.contains(i) }
    var cachedAudioIndices: Set<Int> { Set(audio.keys) }
    var inFlightIndices: Set<Int> { Set(jobs.keys) }

    // MARK: Scheduling

    /// Forget a failure so the next schedule retries it (explicit user visit).
    func clearFailure(_ i: Int) { failed.remove(i) }

    /// The playhead moved (or something finished): cancel out-of-window work,
    /// make sure the playhead section is coming, then prefetch.
    func schedule(playhead current: Int) {
        guard sections.indices.contains(current) else { return }
        playhead = current
        let window = current...min(current + depth, sections.count - 1)

        for (i, job) in jobs where !window.contains(i) {
            job.task.cancel()
            jobs[i] = nil
        }
        let keep = (current - 2)...(current + depth)
        for i in decoded.keys where !keep.contains(i) { decoded[i] = nil }

        if needsWork(current) { startJob(current) }
        guard decoded[current] != nil, jobs.isEmpty else { return }
        if let i = window.first(where: needsWork) { startJob(i) }
    }

    func cancelAll() {
        playhead = nil
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
    }

    /// Synthesize every section still missing audio, in order, one at a time,
    /// without touching playback (e.g. to save the whole narration afterwards).
    /// Returns true when every section has audio.
    @discardableResult
    func synthesizeAll() async -> Bool {
        for i in sections.indices {
            if Task.isCancelled { return false }
            if audio[i] != nil { continue }
            if let job = jobs[i] { await job.task.value }      // reuse in-flight work
            if audio[i] != nil { continue }
            if let speech = try? await synthesize(sections[i]) { audio[i] = speech }
        }
        return audio.count == sections.count
    }

    // MARK: Jobs

    private func needsWork(_ i: Int) -> Bool {
        decoded[i] == nil && jobs[i] == nil && !failed.contains(i)
    }

    private func startJob(_ i: Int) {
        let section = sections[i]
        let synthesize = self.synthesize
        nextJobID += 1
        let id = nextJobID
        let task = Task { [weak self] in
            do {
                let speech: SynthesizedSpeech
                if let cached = self?.audio[i] {
                    speech = cached
                } else {
                    speech = try await synthesize(section)
                    self?.audio[i] = speech      // keep it even if cancelled meanwhile
                }
                try Task.checkCancellation()
                let result = try await Task.detached(priority: .userInitiated) {
                    try SectionDecoder.decode(speech, section: section)
                }.value
                self?.jobFinished(i, id: id, result: .success(result))
            } catch {
                self?.jobFinished(i, id: id, result: .failure(error))
            }
        }
        jobs[i] = Job(id: id, task: task)
    }

    private func jobFinished(_ i: Int, id: Int, result: Result<DecodedSection, Error>) {
        guard jobs[i]?.id == id else { return }      // superseded or cancelled
        jobs[i] = nil
        guard let playhead else { return }
        switch result {
        case .success(let section):
            decoded[i] = section
            onReady?(i)
        case .failure(let err):
            if err is CancellationError || (err as? URLError)?.code == .cancelled { break }
            failed.insert(i)
            onFailed?(i, err)
        }
        // Callbacks may have moved the playhead (and rescheduled); only
        // continue prefetching if they didn't.
        if self.playhead == playhead { schedule(playhead: playhead) }
    }
}
