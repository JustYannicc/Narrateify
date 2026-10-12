import XCTest
@testable import Narrateify

/// Supertonic 3 engine tests. The logic tests always run; anything touching
/// the real model skips unless it's installed at the default location.
/// Set TEST_RUNNER_NARRATEIFY_SUPERTONIC_DOWNLOAD=1 to let `testStoreDownloadsModel`
/// fetch the model (~220 MB Core ML layout) when it's missing.
final class SupertonicTests: XCTestCase {

    // MARK: Text

    func testPreprocessWrapsInLanguageTagAndAddsPeriod() throws {
        XCTAssertEqual(try SupertonicText.preprocess("Hello   world", lang: "en"), "<en>Hello world.</en>")
        XCTAssertEqual(try SupertonicText.preprocess("Wie geht's?", lang: "de"), "<de>Wie geht's?</de>")
    }

    func testPreprocessNormalizesSymbolsAndEmoji() throws {
        let out = try SupertonicText.preprocess("“Hi” — mail me@x 😀 [now]", lang: "en")
        XCTAssertEqual(out, "<en>\"Hi\" - mail me at x now.</en>")
    }

    func testPreprocessRejectsUnknownLanguage() {
        XCTAssertThrowsError(try SupertonicText.preprocess("你好", lang: "zh")) { error in
            guard case SpeechEngineError.unsupportedLanguage = error else { return XCTFail("\(error)") }
        }
    }

    func testChunkerRespectsLimit() {
        XCTAssertEqual(SupertonicChunker.chunk("  \n ", maxLength: 300), [])
        XCTAssertEqual(SupertonicChunker.chunk("Short one.", maxLength: 300), ["Short one."])
        let long = String(repeating: "Dr. Smith went to the shop, bought milk, and came home. ", count: 20)
        let chunks = SupertonicChunker.chunk(long, maxLength: 120)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 120 })
        XCTAssertFalse(chunks.contains { $0.hasSuffix("Dr.") }, "split after an abbreviation")
        let words = String(repeating: "word ", count: 200)
        XCTAssertTrue(SupertonicChunker.chunk(words, maxLength: 50).allSatisfy { $0.count <= 50 })
    }

    // MARK: Engine surface

    func testSupportsThe31Languages() {
        let engine = SupertonicEngine(modelDirectory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(SupertonicText.languages.count, 31)
        for code in ["en-US", "de-DE", "fr-FR", "ja-JP", "ko-KR", "pt-BR", "uk-UA", "vi-VN"] {
            XCTAssertTrue(engine.supports(ReadingLanguage(code: code)), code)
        }
        for code in ["zh-CN", "he-IL", "na"] {
            XCTAssertFalse(engine.supports(ReadingLanguage(code: code)), code)
        }
    }

    func testVoicesAreLanguageAgnostic() async {
        let engine = SupertonicEngine(modelDirectory: URL(fileURLWithPath: "/nonexistent"))
        let voices = await engine.voices(for: .germanDE)
        XCTAssertEqual(voices.map(\.id), SupertonicFiles.voiceIDs)
        XCTAssertTrue(voices.allSatisfy { $0.speaks(.englishUS) && $0.speaks(.germanDE) })
        let none = await engine.voices(for: ReadingLanguage(code: "zh-CN"))
        XCTAssertTrue(none.isEmpty)
    }

    func testMissingModelThrowsNotInstalled() async {
        let engine = SupertonicEngine(modelDirectory: URL(fileURLWithPath: "/nonexistent"))
        do {
            _ = try await engine.synthesize("Hi.", language: .englishUS, voiceID: "F1")
            XCTFail("expected notInstalled")
        } catch SpeechEngineError.notInstalled {
        } catch { XCTFail("\(error)") }
    }

    func testWAVHeader() {
        let wav = WAVEncoder.encode([0, 0.5, -0.5, 1], sampleRate: 44_100)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 44_100)
    }

    func testManifestPerBackend() {
        let common = Set(SupertonicManifest.common.map(\.path))
        XCTAssertTrue(common.isSuperset(of: SupertonicFiles.voiceIDs.map(SupertonicFiles.voiceStyle)))
        XCTAssertEqual(SupertonicManifest.totalBytes(for: .onnx), 401_276_744)
        XCTAssertEqual(SupertonicManifest.totalBytes(for: .coreML), 222_090_203)
        XCTAssertTrue(SupertonicManifest.coreMLDecoder.allSatisfy { $0.url.absoluteString.contains("FluidInference") })
        XCTAssertEqual(Set(SupertonicManifest.files(for: .coreML).map(\.path)).count, 22)
    }

    // MARK: Real model

    private var installedDir: URL { SupertonicModelStore.defaultDirectory }

    private func requireModel() throws {
        try XCTSkipUnless(SupertonicManifest.isComplete(at: installedDir, backend: .current), "Supertonic 3 not installed")
    }

    @MainActor
    func testStoreDownloadsModel() async throws {
        let store = SupertonicModelStore()
        if !store.isInstalled {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["NARRATEIFY_SUPERTONIC_DOWNLOAD"] == "1",
                              "set TEST_RUNNER_NARRATEIFY_SUPERTONIC_DOWNLOAD=1 to download")
            try await store.installAndWait()
        }
        XCTAssertEqual(store.state, .installed)
        XCTAssertGreaterThan(store.diskUsage, SupertonicModelStore.downloadSize * 9 / 10)
    }

    /// Staged files from a previous run are reused (no network) and the
    /// staging folder is swapped into place atomically.
    @MainActor
    func testStoreResumesFromStagingAndUninstalls() async throws {
        try requireModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("supertonic-3")
        let staging = root.appendingPathComponent(".supertonic-3.partial")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: installedDir, to: staging) // APFS clone, cheap

        let store = SupertonicModelStore(directory: dir)
        XCTAssertEqual(store.state, .notInstalled)
        try await store.installAndWait()
        XCTAssertEqual(store.state, .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(SupertonicManifest.isComplete(at: dir, backend: .current))

        try store.uninstall()
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// Size-correct sparse placeholders: enough for the manifest's size checks.
    private func fakeFiles(_ files: [SupertonicManifest.File], in dir: URL) throws {
        for file in files {
            let url = dir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(file.size))
            try h.close()
        }
    }

    /// An ONNX-only install stays usable, offers an upgrade, and the upgrade
    /// reuses the shared files and swaps the Core ML layout in.
    @MainActor
    func testONNXInstallStaysInstalledAndUpgrades() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("supertonic-3")
        try fakeFiles(SupertonicManifest.files(for: .onnx), in: dir)
        // Pretend the Core ML files were already fetched, so no network is needed.
        try fakeFiles(SupertonicManifest.coreMLDecoder, in: root.appendingPathComponent(".supertonic-3.partial"))

        let store = SupertonicModelStore(directory: dir, backend: .coreML)
        XCTAssertEqual(store.state, .installed)
        XCTAssertEqual(store.installedBackend, .onnx)
        XCTAssertTrue(store.isInstalled)
        XCTAssertTrue(store.upgradeAvailable)
        XCTAssertEqual(SupertonicBackend.installed(at: dir, preferred: .coreML), .onnx)

        store.upgrade()
        try await store.installAndWait()
        XCTAssertEqual(store.state, .installed)
        XCTAssertEqual(store.installedBackend, .coreML)
        XCTAssertFalse(store.upgradeAvailable)
        XCTAssertEqual(SupertonicBackend.installed(at: dir, preferred: .coreML), .coreML)
        XCTAssertNil(SupertonicBackend.installed(at: dir, preferred: .onnx), "old ONNX decoder removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".supertonic-3.partial").path))
    }

    func testSynthesizesEnglishAndGerman() async throws {
        try requireModel()
        let out = URL(fileURLWithPath: "/tmp/supertonic-check")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let engine = SupertonicEngine()
        let cases: [(ReadingLanguage, String, String)] = [
            (.englishUS, "F1", "The quick brown fox jumps over the lazy dog, and then it takes a well deserved nap."),
            (.germanDE, "M1", "Der schnelle braune Fuchs springt über den faulen Hund und macht danach ein Nickerchen."),
        ]
        for (lang, voice, text) in cases {
            let speech = try await engine.synthesize(text, language: lang, voiceID: voice)
            XCTAssertEqual(speech.fileExtension, "wav")
            XCTAssertTrue(speech.words.isEmpty)
            let seconds = Double(speech.audio.count - 44) / 2 / 44_100
            XCTAssertGreaterThan(seconds, 3, lang.code)   // ~15 words
            XCTAssertLessThan(seconds, 12, lang.code)
            try speech.audio.write(to: out.appendingPathComponent("test-\(lang.base)-\(voice).wav"))
        }
        XCTAssertTrue(engine.isLoaded)
        XCTAssertEqual(engine.loadedBackend, SupertonicBackend.installed(at: installedDir))
        engine.unload()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(engine.isLoaded)
    }

    func testIdleUnloadAndConcurrentCalls() async throws {
        try requireModel()
        let engine = SupertonicEngine(quality: .fastest, idleUnloadAfter: 0.5)
        // Concurrent calls are serialized, not interleaved on the ORT sessions.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<3 {
                group.addTask {
                    try await engine.synthesize("Sentence number \(i).", language: .englishUS, voiceID: "M2").audio.count
                }
            }
            for try await bytes in group { XCTAssertGreaterThan(bytes, 44_100) }
        }
        XCTAssertTrue(engine.isLoaded)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(engine.isLoaded, "idle timeout should unload")
    }
}
