import Foundation

// Transistor.fm API client. Spec: https://developers.transistor.fm/
enum TransistorError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your Transistor API key in Settings first."
        case .http(let code, let msg): return "Transistor error \(code): \(msg)"
        case .decoding: return "Couldn't parse Transistor's response."
        }
    }
}

struct TransistorAPI {
    static let base = URL(string: "https://api.transistor.fm/v1")!

    var apiKey: String

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw TransistorError.missingAPIKey }
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: - Shows

    func listShows() async throws -> [TransistorShow] {
        let req = try request("shows")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
        let decoded = try JSONDecoder().decode(JSONAPIList.self, from: data)
        return decoded.data.map { TransistorShow(id: $0.id, title: $0.attributes.title ?? "Untitled Show") }
    }

    // MARK: - Upload

    struct AuthorizedUpload {
        let uploadURL: URL
        let contentType: String
        let audioURL: String
    }

    func authorizeUpload(fileName: String) async throws -> AuthorizedUpload {
        let req = try request("episodes/authorize_upload", query: ["filename": fileName])
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
        let decoded = try JSONDecoder().decode(JSONAPISingle<UploadAttributes>.self, from: data)
        guard let uploadURL = URL(string: decoded.data.attributes.upload_url) else { throw TransistorError.decoding }
        return AuthorizedUpload(
            uploadURL: uploadURL,
            contentType: decoded.data.attributes.content_type,
            audioURL: decoded.data.attributes.audio_url
        )
    }

    func uploadAudio(fileURL: URL, to upload: AuthorizedUpload) async throws {
        var req = URLRequest(url: upload.uploadURL)
        req.httpMethod = "PUT"
        req.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        let fileData = try Data(contentsOf: fileURL)
        let (_, response) = try await URLSession.shared.upload(for: req, from: fileData)
        try Self.checkStatus(response, data: Data())
    }

    // MARK: - Episodes

    func createEpisode(draft: EpisodeDraft) async throws -> String {
        guard let showId = draft.showId else { throw TransistorError.http(422, "No show selected") }
        var form = [
            "episode[show_id]": showId,
            "episode[title]": draft.title,
            "episode[summary]": draft.summary,
            "episode[description]": draft.description,
            "episode[explicit]": draft.explicit ? "true" : "false"
        ]
        if let audioURL = draft.transistorAudioURL { form["episode[audio_url]"] = audioURL }
        if !draft.season.isEmpty { form["episode[season]"] = draft.season }
        if !draft.number.isEmpty { form["episode[number]"] = draft.number }

        var req = try request("episodes", method: "POST")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
        let decoded = try JSONDecoder().decode(JSONAPISingle<EpisodeAttributes>.self, from: data)
        return decoded.data.id
    }

    func updateEpisode(id: String, draft: EpisodeDraft) async throws {
        var form = [
            "episode[title]": draft.title,
            "episode[summary]": draft.summary,
            "episode[description]": draft.description,
            "episode[explicit]": draft.explicit ? "true" : "false"
        ]
        if let audioURL = draft.transistorAudioURL { form["episode[audio_url]"] = audioURL }
        if !draft.season.isEmpty { form["episode[season]"] = draft.season }
        if !draft.number.isEmpty { form["episode[number]"] = draft.number }

        var req = try request("episodes/\(id)", method: "PATCH")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
    }

    /// status: "draft", "scheduled", or "published"
    func publishEpisode(id: String, status: String, publishedAt: Date? = nil) async throws {
        var form = ["episode[status]": status]
        if let publishedAt {
            let formatter = ISO8601DateFormatter()
            form["episode[published_at]"] = formatter.string(from: publishedAt)
        }
        var req = try request("episodes/\(id)/publish", method: "PATCH")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
    }

    // MARK: - Helpers

    private static func formEncode(_ params: [String: String]) -> Data {
        params.map { key, value in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(.init(charactersIn: "&=+"))
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TransistorError.http(http.statusCode, body)
        }
    }
}

// MARK: - JSON:API decoding shapes

private struct JSONAPIList: Decodable {
    let data: [JSONAPIResource<ShowAttributes>]
}

private struct JSONAPISingle<A: Decodable>: Decodable {
    let data: JSONAPIResource<A>
}

private struct JSONAPIResource<A: Decodable>: Decodable {
    let id: String
    let attributes: A
}

private struct ShowAttributes: Decodable {
    let title: String?
}

private struct UploadAttributes: Decodable {
    let upload_url: String
    let content_type: String
    let audio_url: String
}

private struct EpisodeAttributes: Decodable {
    let title: String?
}
