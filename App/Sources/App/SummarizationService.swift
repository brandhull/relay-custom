import Foundation
import FoundationModels

/// Wraps Apple's on-device Foundation Models framework. Gated behind
/// iOS 26 + an Apple Intelligence-eligible device — callers must check
/// `isAvailable()` (or catch the thrown error) and fall back to the raw
/// transcript when it's false, since not every device this app could run
/// on supports it.
@available(iOS 26.0, macOS 26.0, *)
enum SummarizationService {
    static func isAvailable() -> Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    static func summarize(_ transcript: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: "You summarize podcast recording transcripts. Be concise, preserve key points, names, and any action items. Keep it well under 200 words. Write plain prose, no headers."
        )
        let response = try await session.respond(to: "Summarize this transcript:\n\n\(transcript)")
        return response.content
    }

    /// A short episode title from the start of a transcript. Only the first
    /// few thousand characters are sent — plenty to name a recording, and it
    /// keeps the prompt inside the on-device model's context window.
    static func suggestTitle(_ transcript: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: "You write titles for podcast recordings. Reply with one title only: at most 8 words, in sentence case (capitalize only the first word and proper nouns, never all caps), no quotation marks, no trailing punctuation, no preamble."
        )
        let response = try await session.respond(to: "Title this recording based on its transcript:\n\n\(String(transcript.prefix(3000)))")
        let title = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        // The model sometimes ignores the casing instruction and shouts; fall
        // back to plain sentence case rather than ever showing all caps.
        if title.count > 3, title == title.uppercased() {
            return title.prefix(1).uppercased() + title.dropFirst().lowercased()
        }
        return title
    }

    /// Fixes sentence breaks and punctuation on a full transcript without
    /// altering wording — automatic pause-based punctuation (see
    /// `AppleSpeechAnalyzerService`) occasionally reads a mid-thought pause
    /// as a sentence end. Opt-in (see `AppSettings.cleanupPunctuationEnabled`)
    /// since an LLM asked to "only fix punctuation" can still occasionally
    /// reword something despite instructions not to.
    static func cleanupPunctuation(_ transcript: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: "You fix punctuation and sentence boundaries in speech-to-text transcripts. Correct only punctuation, capitalization, and sentence breaks. Do not add, remove, reorder, or reword anything — every word must stay exactly as given, in the same order. Return only the corrected transcript, nothing else."
        )
        let response = try await session.respond(to: transcript)
        return response.content
    }
}
