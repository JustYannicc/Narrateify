import Foundation

/// Cloud synthesis via OpenAI's `/v1/audio/speech` endpoint. Returns MP3 bytes.
struct OpenAIClient {
    let apiKey: String
    let voice: String
    let model: String
    let speed: Double

    enum OpenAIError: LocalizedError {
        case missingKey
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Enter your OpenAI API key in Settings → Models."
            case .http(let code, let body):
                let detail = body.isEmpty ? "" : " – \(body.prefix(200))"
                return "OpenAI error \(code)\(detail)"
            case .empty:
                return "OpenAI returned no audio."
            }
        }
    }

    func synthesize(text: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw OpenAIError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        // Only the `tts-1*` models accept a speed parameter.
        if model.hasPrefix("tts-") { body["speed"] = speed }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard !data.isEmpty else { throw OpenAIError.empty }
        return data
    }

    /// OpenAI's built-in voices.
    static let voices: [String] = [
        "alloy", "ash", "ballad", "coral", "echo",
        "fable", "onyx", "nova", "sage", "shimmer", "verse"
    ]

    static let models: [(id: String, label: String)] = [
        ("gpt-4o-mini-tts", "GPT-4o mini TTS — newest, steerable"),
        ("tts-1",           "TTS-1 — fast"),
        ("tts-1-hd",        "TTS-1 HD — higher quality")
    ]

    /// Approximate USD per 1,000 characters, for the History cost estimate.
    /// Used by the character-billed `tts-1*` models (and as a pre-synthesis
    /// fallback for `gpt-4o-mini-tts`, which is reconciled to audio minutes once
    /// the duration is known — see `pricePerMinute`).
    static func pricePerThousand(model: String) -> Double {
        switch model {
        case "tts-1-hd": return 0.030
        default:         return 0.015
        }
    }

    /// Approximate USD per minute of generated audio, for `gpt-4o-mini-tts`,
    /// which bills on tokens (≈ audio duration) rather than input characters.
    static let pricePerMinute = 0.015
}
