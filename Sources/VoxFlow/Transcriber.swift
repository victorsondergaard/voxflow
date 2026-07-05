import Foundation

enum TranscriberError: Error, LocalizedError {
    case serverUnreachable
    case badResponse

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "The transcription server is not responding."
        case .badResponse:
            return "The transcription server returned an unexpected response."
        }
    }
}

/// HTTP client for whisper-server's /inference endpoint.
struct Transcriber {
    /// Sends WAV audio to whisper-server; returns cleaned raw transcript.
    /// `language` is "en" or "auto" (SPEC R9).
    func transcribe(wav: Data, port: Int, language: String) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else {
            throw TranscriberError.serverUnreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300 // long dictations allowed (SPEC edge cases)

        let boundary = "----VoxFlowBoundary\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        func textField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        textField("response_format", "json")
        textField("language", language)
        textField("temperature", "0.0")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriberError.serverUnreachable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriberError.badResponse
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw TranscriberError.badResponse
        }
        return Transcriber.stripArtifacts(from: text)
    }

    /// Removes whisper non-speech artifacts like [BLANK_AUDIO], [MUSIC], (bell dings) and trims (SPEC R10).
    static func stripArtifacts(from text: String) -> String {
        var result = text
        // Bracketed tags: [BLANK_AUDIO], [MUSIC], [_TT_500] ...
        result = result.replacingOccurrences(
            of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        // Parenthesised sound descriptions on a line of their own: (bell dings), (music)
        result = result.replacingOccurrences(
            of: #"(?m)^\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        // A pause while thinking is NOT a paragraph: whisper marks segment
        // boundaries with newlines — flatten them into normal spaces.
        result = result.replacingOccurrences(
            of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
        // Collapse runs of whitespace left behind.
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
