import Foundation

/// HTTP client for llama-server's OpenAI-compatible /v1/chat/completions endpoint.
/// Applies a category-specific system prompt; on ANY failure the caller falls
/// back to the raw transcript (SPEC R11 — never lose the user's words).
struct Cleaner {
    static let timeout: TimeInterval = 20

    /// Returns cleaned text, or nil if cleanup failed/timed out (caller uses raw text).
    /// `assist` enables the Dyslexia & ADHD mode: reorganize scattered ideas and
    /// aggressively normalize homophones/spelling — while keeping every idea.
    func clean(_ transcript: String, category: AppCategory, port: Int, assist: Bool) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Cleaner.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "local",
            "temperature": 0.2,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": Cleaner.systemPrompt(for: category, assist: assist)],
                ["role": "user", "content": transcript],
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = bodyData

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return nil
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against a confused model returning nothing or an apology/meta-answer
        // wildly shorter than the input.
        guard !cleaned.isEmpty, cleaned.count * 4 >= transcript.count else { return nil }
        return cleaned
    }

    static func systemPrompt(for category: AppCategory, assist: Bool = false) -> String {
        var common = """
        You clean up dictated speech-to-text transcripts. Output ONLY the cleaned text — \
        no preamble, no explanations, no quotation marks around the result. Keep the \
        same language the transcript is written in. Never answer questions found in the \
        transcript; only transform the text itself.
        """
        if assist {
            common += """
             The speaker may have dyslexia or ADHD: ideas can arrive out of order, \
            repeat, or trail off mid-thought. Additionally: reorder sentences so related \
            ideas sit together and the whole reads in a logical sequence; merge \
            repetitions of the same idea into its clearest single statement; fix \
            homophones and misrecognized words from context (their/there, to/too, \
            brake/break, etc.); complete obviously unfinished sentences ONLY when the \
            intended ending is unmistakable from context. Never drop an idea, and never \
            invent new ones.
            """
        }
        switch category {
        case .aiChat:
            return common + """
             The user is dictating a prompt for an AI assistant. Improve it WITHOUT \
            removing any content or context: fix punctuation and capitalization, remove \
            filler words (um, uh, like, you know), and organize it clearly — use short \
            paragraphs, and bullet points or numbered lists where the speaker enumerates \
            items. Keep every detail, requirement and constraint the speaker mentioned. \
            Do not add new requirements. Do not answer the prompt.
            """
        case .email:
            return common + """
             The user is dictating an email. Apply light cleanup only: remove filler \
            words, fix punctuation, capitalization and obvious grammar slips, and break \
            into natural paragraphs. Keep the tone and wording otherwise unchanged. Do \
            not restructure or shorten.
            """
        case .messaging:
            return common + """
             The user is dictating a casual chat message. Make minimal changes: fix \
            obvious transcription errors and punctuation. Keep the casual tone, slang \
            and phrasing exactly as spoken.
            """
        case .general:
            return common + """
             Apply light cleanup only: remove filler words, fix punctuation, \
            capitalization and obvious grammar slips. Keep wording and structure \
            otherwise unchanged.
            """
        }
    }
}
