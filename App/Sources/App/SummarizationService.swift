import Foundation
import FoundationModels

/// Wraps Apple's on-device Foundation Models framework. Gated behind
/// iOS 26 + an Apple Intelligence-eligible device — callers must check
/// `isAvailable()` (or catch the thrown error) and fall back to the raw
/// transcript when it's false, since not every device this app could run
/// on supports it.
@available(iOS 26.0, *)
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
}
