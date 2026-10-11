import XCTest
@testable import Narrateify

/// Edge TTS: token, framing, SSML, and word alignment with fixtures (no network).
/// Live checks at the bottom only run with `TEST_RUNNER_EDGE_LIVE=1`.
final class EdgeTTSTests: XCTestCase {

    // MARK: Token

    /// Tokens captured from real edge-tts 7.2.8 request URLs in rany2/edge-tts#490
    /// (2026-10-10 12:30 and 17:15 UTC windows).
    func testSecMSGECMatchesReferenceImplementation() {
        let key = EdgeEndpointV1.trustedClientToken
        XCTAssertEqual(EdgeToken.secMSGEC(unixTime: 1_791_635_400, clientToken: key),
                       "FC40D9F01D4ED2AC01CE43500018D9CC677D49324E40A968404A7BE33C195B41")
        XCTAssertEqual(EdgeToken.secMSGEC(unixTime: 1_791_652_500, clientToken: key),
                       "4429B7DDBBC3A17892C1E6FABACDA0E7CC4A00FB0EFD36081F74C450633150EF")
    }

    func testSecMSGECRoundsDownToFiveMinutes() {
        let key = EdgeEndpointV1.trustedClientToken
        let a = EdgeToken.secMSGEC(unixTime: 1_791_635_400, clientToken: key)
        XCTAssertEqual(EdgeToken.secMSGEC(unixTime: 1_791_635_400 + 299.9, clientToken: key), a)
        XCTAssertNotEqual(EdgeToken.secMSGEC(unixTime: 1_791_635_400 + 300, clientToken: key), a)
        XCTAssertNotEqual(EdgeToken.secMSGEC(unixTime: 1_791_635_400 - 0.1, clientToken: key), a)
    }

    func testV1RequestCarriesTokenAndHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_791_635_400)
        let r = EdgeEndpointV1(host: .bing).synthesisRequest(connectionID: "abc", now: now)
        let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let items = Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(r.url?.scheme, "wss")
        XCTAssertEqual(items["Sec-MS-GEC"], "FC40D9F01D4ED2AC01CE43500018D9CC677D49324E40A968404A7BE33C195B41")
        XCTAssertEqual(items["Sec-MS-GEC-Version"], "1-\(EdgeEndpointV1.chromiumFullVersion)")
        XCTAssertEqual(items["ConnectionId"], "abc")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Origin"), EdgeEndpointV1.origin)
        XCTAssertTrue(r.value(forHTTPHeaderField: "User-Agent")!.contains("Edg/"))
        XCTAssertEqual(r.url?.host, "speech.platform.bing.com")
        XCTAssertEqual(items["TrustedClientToken"], EdgeEndpointV1.trustedClientToken)

        let n = EdgeEndpointV1(host: .msEdgeServices).synthesisRequest(connectionID: "abc", now: now)
        let nq = URLComponents(url: n.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(n.url?.host, "api.msedgeservices.com")
        XCTAssertEqual(n.url?.path, "/tts/cognitiveservices/websocket/v1")
        XCTAssertTrue(nq.contains(URLQueryItem(name: "Ocp-Apim-Subscription-Key", value: EdgeEndpointV1.trustedClientToken)))
        XCTAssertTrue(nq.contains(URLQueryItem(name: "Sec-MS-GEC", value: items["Sec-MS-GEC"])))
        XCTAssertEqual(EdgeEndpointV1.all.map(\.name), ["v1@msEdgeServices", "v1@bing"])
    }

    func testHTTPDateParsing() {
        let d = EdgeClock.parseHTTPDate("Sun, 11 Oct 2026 08:27:16 GMT")
        XCTAssertEqual(d?.timeIntervalSince1970, 1_791_707_236)
    }

    // MARK: Framing

    func testSpeechConfigMessage() {
        let m = EdgeProtocol.speechConfigMessage(timestamp: "T")
        XCTAssertTrue(m.hasPrefix("X-Timestamp:T\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"))
        let json = m.components(separatedBy: "\r\n\r\n")[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let audio = ((obj["context"] as! [String: Any])["synthesis"] as! [String: Any])["audio"] as! [String: Any]
        XCTAssertEqual(audio["outputFormat"] as? String, "audio-24khz-48kbitrate-mono-mp3")
        XCTAssertEqual((audio["metadataoptions"] as! [String: String])["wordBoundaryEnabled"], "true")
    }

    func testSSMLMessageFraming() {
        let m = EdgeProtocol.ssmlMessage(requestID: "rid", timestamp: "T", ssml: "<speak/>")
        XCTAssertEqual(m, "X-RequestId:rid\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:TZ\r\nPath:ssml\r\n\r\n<speak/>")
    }

    func testTimestampIsJavaScriptStyleUTC() {
        let s = EdgeProtocol.timestamp(Date(timeIntervalSince1970: 1_791_707_236))
        XCTAssertEqual(s, "Sun Oct 11 2026 08:27:16 GMT+0000 (Coordinated Universal Time)")
    }

    func testParseTextFrame() throws {
        let body = #"{"Metadata":[{"Type":"WordBoundary","Data":{"Offset":1000000,"Duration":3250000,"text":{"Text":"Hello","Length":5,"BoundaryType":"WordBoundary"}}}]}"#
        let raw = "X-RequestId:abc\r\nContent-Type:application/json; charset=utf-8\r\nPath:audio.metadata\r\n\r\n" + body
        let f = try EdgeProtocol.parseTextFrame(raw)
        XCTAssertEqual(f.path, "audio.metadata")
        XCTAssertEqual(f.headers["X-RequestId"], "abc")
        let b = try EdgeProtocol.parseMetadata(f.body)
        XCTAssertEqual(b, [.init(kind: .word, text: "Hello", offset: 1_000_000, duration: 3_250_000)])
        XCTAssertEqual(b[0].start, 0.1, accuracy: 1e-9)
        XCTAssertEqual(b[0].seconds, 0.325, accuracy: 1e-9)

        let end = try EdgeProtocol.parseTextFrame("X-RequestId:abc\r\nPath:turn.end\r\n\r\n{}")
        XCTAssertEqual(end.path, "turn.end")
        XCTAssertThrowsError(try EdgeProtocol.parseTextFrame("no separator"))
    }

    func testParseMetadataSkipsSessionEndAndUnescapes() throws {
        let body = #"{"Metadata":[{"Type":"SessionEnd","Data":{"Offset":0}},{"Type":"WordBoundary","Data":{"Offset":5,"Duration":6,"text":{"Text":"Tom&amp;Jerry","Length":13,"BoundaryType":"WordBoundary"}}},{"Type":"WordBoundary","Data":{"Offset":7,"Duration":1,"text":{"Text":",","Length":1,"BoundaryType":"PunctuationBoundary"}}}]}"#
        let b = try EdgeProtocol.parseMetadata(Data(body.utf8))
        XCTAssertEqual(b.map(\.text), ["Tom&Jerry", ","])
        XCTAssertEqual(b.map(\.kind), [.word, .punctuation])
        XCTAssertThrowsError(try EdgeProtocol.parseMetadata(Data("[]".utf8)))
    }

    private func binaryFrame(headers: String, payload: [UInt8]) -> Data {
        let h = Array(headers.utf8)
        return Data([UInt8(h.count >> 8), UInt8(h.count & 0xFF)] + h + payload)
    }

    func testParseBinaryAudioFrame() throws {
        let headers = "X-RequestId:abc\r\nContent-Type:audio/mpeg\r\nX-StreamId:1\r\nPath:audio\r\n"
        let f = try EdgeProtocol.parseBinaryFrame(binaryFrame(headers: headers, payload: [0xFF, 0xF3, 0x01, 0x02]))
        XCTAssertEqual(f.path, "audio")
        XCTAssertEqual(f.headers["Content-Type"], "audio/mpeg")
        XCTAssertEqual(f.body, Data([0xFF, 0xF3, 0x01, 0x02]))
    }

    func testParseBinaryFrameEdgeCases() throws {
        // End-of-stream frame: audio path, no content type, no payload.
        let f = try EdgeProtocol.parseBinaryFrame(binaryFrame(headers: "X-RequestId:abc\r\nPath:audio\r\n", payload: []))
        XCTAssertEqual(f.path, "audio")
        XCTAssertNil(f.headers["Content-Type"])
        XCTAssertTrue(f.body.isEmpty)
        // Works on a slice whose indices don't start at 0.
        let padded = Data([0xAA]) + binaryFrame(headers: "Path:audio\r\n", payload: [1, 2])
        XCTAssertEqual(try EdgeProtocol.parseBinaryFrame(padded.dropFirst()).body, Data([1, 2]))
        XCTAssertThrowsError(try EdgeProtocol.parseBinaryFrame(Data([0x00])))
        XCTAssertThrowsError(try EdgeProtocol.parseBinaryFrame(Data([0x00, 0x10, 0x41])))
    }

    // MARK: SSML

    func testSSMLEscaping() {
        XCTAssertEqual(EdgeProtocol.escapeXML(#"a < b & c > "d" 'e'"#),
                       "a &lt; b &amp; c &gt; &quot;d&quot; &apos;e&apos;")
        XCTAssertEqual(EdgeProtocol.unescapeXML("a &lt; b &amp;lt; &apos;"), "a < b &lt; '")
        XCTAssertEqual(EdgeProtocol.escapeXML("Grüße 👋🏽"), "Grüße 👋🏽")
    }

    func testSSMLDocument() {
        let s = EdgeProtocol.ssml(text: "Fish & <chips>\u{0B}ok", voiceID: "de-DE-KatjaNeural", languageCode: "de-DE")
        XCTAssertTrue(s.contains("xml:lang='de-DE'"))
        XCTAssertTrue(s.contains("<voice name='Microsoft Server Speech Text to Speech Voice (de-DE, KatjaNeural)'>"))
        XCTAssertTrue(s.contains("rate='+0%'"))
        XCTAssertTrue(s.contains("Fish &amp; &lt;chips&gt; ok"))
        XCTAssertNotNil(try? XMLDocument(xmlString: s), "SSML must be well-formed XML")
    }

    func testLongVoiceName() {
        XCTAssertEqual(EdgeProtocol.longVoiceName("en-US-AvaMultilingualNeural"),
                       "Microsoft Server Speech Text to Speech Voice (en-US, AvaMultilingualNeural)")
        XCTAssertEqual(EdgeProtocol.longVoiceName("zh-CN-liaoning-XiaobeiNeural"),
                       "Microsoft Server Speech Text to Speech Voice (zh-CN-liaoning, XiaobeiNeural)")
        XCTAssertEqual(EdgeProtocol.longVoiceName("Microsoft Server Speech Text to Speech Voice (en-US, AriaNeural)"),
                       "Microsoft Server Speech Text to Speech Voice (en-US, AriaNeural)")
    }

    // MARK: Word alignment

    private func words(_ list: [String]) -> [EdgeProtocol.Boundary] {
        list.enumerated().map { i, w in
            .init(kind: w.allSatisfy(\.isPunctuation) ? .punctuation : .word,
                  text: w, offset: Int64(i) * 5_000_000, duration: 4_000_000)
        }
    }

    private func substrings(_ timings: [WordTiming], _ text: String) -> [String] {
        timings.map { (text as NSString).substring(with: $0.range) }
    }

    func testAlignSimpleWithTimes() {
        let text = "Hello, world!"
        let t = EdgeWordAligner.align(words(["Hello", ",", "world", "!"]), in: text)
        XCTAssertEqual(substrings(t, text), ["Hello", "world"])
        XCTAssertEqual(t[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(t[1].range, NSRange(location: 7, length: 5))
        XCTAssertEqual(t[1].start, 1.0, accuracy: 1e-9)  // 3rd boundary (after ",")
        XCTAssertEqual(t[1].duration, 0.4, accuracy: 1e-9)
    }

    func testAlignRepeatedWordsAdvanceSequentially() {
        let text = "the cat and the hat and the bat"
        let t = EdgeWordAligner.align(words(text.components(separatedBy: " ")), in: text)
        XCTAssertEqual(t.count, 8)
        XCTAssertEqual(t.map(\.range.location), [0, 4, 8, 12, 16, 20, 24, 28])
    }

    func testAlignApostrophesAndTypographicQuotes() {
        let text = "Don’t say “it’s fine”."
        // Service may echo either the curly or the straight apostrophe.
        let t = EdgeWordAligner.align(words(["Don't", "say", "it’s", "fine"]), in: text)
        XCTAssertEqual(substrings(t, text), ["Don’t", "say", "it’s", "fine"])
    }

    func testAlignUmlautsEmojiAndUTF16Ranges() {
        let text = "Grüße 👋🏽 aus Zürich, Straße"
        let t = EdgeWordAligner.align(words(["Grüße", "aus", "Zürich", "Straße"]), in: text)
        XCTAssertEqual(substrings(t, text), ["Grüße", "aus", "Zürich", "Straße"])
        // "👋🏽" is 4 UTF-16 units: "aus" starts at 6 + 4 + 1 = 11.
        XCTAssertEqual(t[1].range, NSRange(location: 11, length: 3))
    }

    func testAlignDecomposedUmlautsAndCaseFolding() {
        let text = "Gru\u{0308}ße ZÜRICH"  // decomposed ü
        let t = EdgeWordAligner.align(words(["Grüße", "zürich"]), in: text)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[1].range, NSRange(location: 7, length: 6))
    }

    func testAlignSkipsUnfoundWordsWithoutLosingPlace() {
        let text = "Dr. Smith paid $5 today a while ago"
        // "Doctor"/"five dollars" are rewritten by the service and don't appear;
        // they must not derail the following words.
        let t = EdgeWordAligner.align(words(["Doctor", "Smith", "paid", "five", "dollars", "today"]), in: text)
        XCTAssertEqual(substrings(t, text), ["Smith", "paid", "today"])
    }

    func testAlignDoesNotJumpFarAhead() {
        let filler = String(repeating: "lorem ipsum ", count: 20)
        let text = "alpha " + filler + "zeta beta"
        let t = EdgeWordAligner.align(words(["alpha", "zeta", "lorem"]), in: text)
        // "zeta" is >80 units away → dropped; "lorem" still matches right after alpha.
        XCTAssertEqual(substrings(t, text), ["alpha", "lorem"])
        XCTAssertEqual(t[1].range.location, 6)
    }

    func testAlignEscapedSymbols() {
        let text = "Fish & chips <3"
        let t = EdgeWordAligner.align(words(["Fish", "&", "chips", "3"]), in: text)
        XCTAssertEqual(substrings(t, text), ["Fish", "chips", "3"])
    }

    // MARK: Voices

    func testVoiceFilteringAndDisplay() {
        let v = EdgeVoiceCatalog.filter(EdgeVoiceCatalog.fallback, for: .germanDE)
        XCTAssertTrue(v.allSatisfy { $0.locale == "de-DE" })
        XCTAssertTrue(v.first!.isMultilingual, "multilingual voices sort first")
        let ids = Set(v.map(\.shortName))
        for id in ["de-DE-SeraphinaMultilingualNeural", "de-DE-FlorianMultilingualNeural", "de-DE-KatjaNeural", "de-DE-ConradNeural"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let ava = EdgeVoice(shortName: "en-US-AvaMultilingualNeural", locale: "en-US", gender: "Female")
        XCTAssertEqual(ava.option.name, "Ava (Multilingual) · Female")
        XCTAssertEqual(ava.option.languages, ["en-US"])
        XCTAssertTrue(ava.option.speaks(.englishUS))
        // Base-only fallback: no exact de-LI voices, so any de-* qualifies.
        XCTAssertFalse(EdgeVoiceCatalog.filter(EdgeVoiceCatalog.fallback, for: ReadingLanguage(code: "de-LI")).isEmpty)
    }

    func testVoiceListDecodingAndCacheRoundTrip() throws {
        let json = #"[{"Name":"x","ShortName":"de-DE-KatjaNeural","Gender":"Female","Locale":"de-DE","FriendlyName":"Microsoft Katja Online (Natural) - German (Germany)","Status":"GA","VoiceTag":{"ContentCategories":["General"],"VoicePersonalities":["Friendly"]}}]"#
        let v = try JSONDecoder().decode([EdgeVoice].self, from: Data(json.utf8))
        XCTAssertEqual(v.first, EdgeVoice(shortName: "de-DE-KatjaNeural", locale: "de-DE", gender: "Female",
                                          friendlyName: "Microsoft Katja Online (Natural) - German (Germany)"))
        let again = try JSONDecoder().decode([EdgeVoice].self, from: JSONEncoder().encode(v))
        XCTAssertEqual(again, v)
    }

    func testEngineSupportsFallbackLocales() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = EdgeTTSEngine(catalog: EdgeVoiceCatalog(cacheURL: dir.appendingPathComponent("v.json")))
        XCTAssertEqual(engine.kind, .edge)
        XCTAssertTrue(engine.supports(.englishUS))
        XCTAssertTrue(engine.supports(.germanDE))
    }

    // MARK: Failure classification (local, no Microsoft traffic)

    /// A server that never answers the handshake must fail fast as serviceUnavailable.
    func testConnectTimeoutMapsToServiceUnavailable() async throws {
        let engine = EdgeTTSEngine(endpoint: BlackholeEndpoint(), connectTimeout: 1)
        let start = Date()
        do {
            _ = try await engine.synthesize("Hello there.", language: .englishUS, voiceID: "en-US-AriaNeural")
            XCTFail("expected failure")
        } catch let e as SpeechEngineError {
            guard case .serviceUnavailable = e else { return XCTFail("got \(e)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: Live (opt-in)

    private var live: Bool { ProcessInfo.processInfo.environment["EDGE_LIVE"] == "1" }

    func testLiveVoiceList() async throws {
        try XCTSkipUnless(live, "set TEST_RUNNER_EDGE_LIVE=1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for ep in EdgeEndpointV1.all {
            let one = EdgeVoiceCatalog(endpoints: [ep], cacheURL: dir.appendingPathComponent("\(ep.name).json"))
            let t0 = Date()
            let n = await one.refresh()?.count ?? -1
            print("EDGE-LIVE voice list \(ep.name): \(n) voices in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        }
        let catalog = EdgeVoiceCatalog(cacheURL: dir.appendingPathComponent("v.json"))
        let start = Date()
        let fetched = await catalog.refresh()
        print("EDGE-LIVE voice list: \(fetched?.count ?? -1) voices in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        let all = try XCTUnwrap(fetched)
        let names = Set(all.map(\.shortName))
        let missing = EdgeVoiceCatalog.fallback.map(\.shortName).filter { !names.contains($0) }
        print("EDGE-LIVE fallback voices missing from live list: \(missing)")
        XCTAssertTrue(missing.isEmpty)
    }

    func testLiveSynthesis() async throws {
        try XCTSkipUnless(live, "set TEST_RUNNER_EDGE_LIVE=1")
        let out = URL(fileURLWithPath: "/tmp/edge-check", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let engine = EdgeTTSEngine()
        let cases: [(String, ReadingLanguage, String, String)] = [
            ("en", .englishUS, "en-US-AvaMultilingualNeural",
             "Don't panic: the cat & the hat met the cat again at 5 o'clock, didn't they?"),
            ("de", .germanDE, "de-DE-SeraphinaMultilingualNeural",
             "Grüße aus Zürich! Die Straße ist überfüllt, aber das Café hat noch offen."),
        ]
        for (tag, lang, voice, text) in cases {
            let start = Date()
            do {
                let s = try await engine.synthesize(text, language: lang, voiceID: voice)
                let elapsed = Date().timeIntervalSince(start)
                let file = out.appendingPathComponent("\(tag).mp3")
                try s.audio.write(to: file)
                print("EDGE-LIVE \(tag): OK \(s.audio.count) bytes, \(s.words.count) words, \(String(format: "%.2f", elapsed)) s → \(file.path)")
                for w in s.words {
                    print(String(format: "EDGE-LIVE \(tag)   %6.3f +%5.3f  %@", w.start, w.duration,
                                 (text as NSString).substring(with: w.range)))
                }
                XCTAssertGreaterThan(s.words.count, 8)
            } catch {
                print("EDGE-LIVE \(tag): FAILED after \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(error)")
                throw error
            }
        }
    }
}

extension EdgeTTSTests {
    /// Repeated short syntheses: how often v1 gets through, and how fast
    /// failures return (single-attempt engine vs. default retries).
    func testLiveHandshakeReliability() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EDGE_LIVE"] == "1", "set TEST_RUNNER_EDGE_LIVE=1")
        let engines: [(String, EdgeTTSEngine)] = [
            ("bing, 1 try", EdgeTTSEngine(endpoint: EdgeEndpointV1(host: .bing), handshakeAttempts: 1)),
            ("msedgeservices, 1 try", EdgeTTSEngine(endpoint: EdgeEndpointV1(host: .msEdgeServices), handshakeAttempts: 1)),
            ("default", EdgeTTSEngine()),
        ]
        for (label, engine) in engines {
            var ok = 0, fail = 0, okTimes: [Double] = [], failTimes: [Double] = []
            for _ in 0..<8 {
                let start = Date()
                do {
                    _ = try await engine.synthesize("Quick check.", language: .englishUS, voiceID: "en-US-AriaNeural")
                    ok += 1; okTimes.append(Date().timeIntervalSince(start))
                } catch {
                    fail += 1; failTimes.append(Date().timeIntervalSince(start))
                    print("EDGE-LIVE reliability [\(label)] error: \(error)")
                }
            }
            func fmt(_ a: [Double]) -> String { a.map { String(format: "%.2f", $0) }.joined(separator: " ") }
            print("EDGE-LIVE reliability [\(label)]: \(ok) ok (\(fmt(okTimes)) s), \(fail) failed (\(fmt(failTimes)) s)")
        }
    }
}

extension EdgeTTSTests {
    func testRefusedConnectionFailsFastAsServiceUnavailable() async throws {
        let engine = EdgeTTSEngine(endpoint: FixedURLEndpoint(url: "ws://127.0.0.1:1/"))
        let start = Date()
        do {
            _ = try await engine.synthesize("Hello.", language: .englishUS, voiceID: "en-US-AriaNeural")
            XCTFail("expected failure")
        } catch SpeechEngineError.serviceUnavailable {
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    /// Real Microsoft host, deliberately invalid token → 403 on every try.
    /// Measures the worst-case "rejected everywhere" latency with retries.
    func testLiveRejectedHandshakeFailsFast() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EDGE_LIVE"] == "1", "set TEST_RUNNER_EDGE_LIVE=1")
        let engine = EdgeTTSEngine(endpoints: [BadTokenEndpoint(), BadTokenEndpoint()])
        let start = Date()
        do {
            _ = try await engine.synthesize("Hello.", language: .englishUS, voiceID: "en-US-AriaNeural")
            XCTFail("expected failure")
        } catch let e as SpeechEngineError {
            let elapsed = Date().timeIntervalSince(start)
            print("EDGE-LIVE rejected-everywhere: \(e) after \(String(format: "%.2f", elapsed)) s")
            guard case .serviceUnavailable = e else { return XCTFail("got \(e)") }
            XCTAssertLessThan(elapsed, 3)
        }
    }
}

private struct FixedURLEndpoint: EdgeEndpoint {
    let url: String
    var name: String { "fixed" }
    func synthesisRequest(connectionID: String, now: Date) -> URLRequest { URLRequest(url: URL(string: url)!) }
    func voiceListRequest(now: Date) -> URLRequest { URLRequest(url: URL(string: url)!) }
    func token(now: Date) -> String { "" }
}

private struct BadTokenEndpoint: EdgeEndpoint {
    var name: String { "bad-token" }
    func synthesisRequest(connectionID: String, now: Date) -> URLRequest {
        var r = EdgeEndpointV1(host: .msEdgeServices).synthesisRequest(connectionID: connectionID, now: now)
        var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        c.queryItems = c.queryItems!.map { $0.name == "Sec-MS-GEC" ? URLQueryItem(name: $0.name, value: "00") : $0 }
        r.url = c.url
        return r
    }
    func voiceListRequest(now: Date) -> URLRequest { EdgeEndpointV1().voiceListRequest(now: now) }
    func token(now: Date) -> String { "00" }
}

/// Points the engine at a local TCP port that accepts but never answers, to
/// exercise the connect deadline without touching Microsoft.
private struct BlackholeEndpoint: EdgeEndpoint {
    var name: String { "blackhole" }
    // 10.255.255.1 is unroutable: the TCP connect hangs until our deadline.
    func synthesisRequest(connectionID: String, now: Date) -> URLRequest {
        URLRequest(url: URL(string: "ws://10.255.255.1:9/")!)
    }
    func voiceListRequest(now: Date) -> URLRequest { URLRequest(url: URL(string: "http://10.255.255.1:9/")!) }
    func token(now: Date) -> String { "" }
}
