import Foundation

// Minimal Baserow REST client: uploads the audio file, then creates/updates
// a row in the configured table with episode details + the file attachment.
enum BaserowError: LocalizedError {
    case missingConfig
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingConfig: return "Add your Baserow token and table ID in Settings first."
        case .http(let code, let msg): return "Baserow error \(code): \(msg)"
        }
    }
}

struct BaserowAPI {
    var token: String
    var tableId: String
    var baseURL = URL(string: "https://api.baserow.io")!

    private func authedRequest(_ url: URL, method: String) throws -> URLRequest {
        guard !token.isEmpty, !tableId.isEmpty else { throw BaserowError.missingConfig }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Uploads the audio file to Baserow's file store; returns the file object
    /// to embed in a File field, e.g. `[{"name": returned_name}]`.
    func uploadFile(fileURL: URL) async throws -> [String: Any] {
        let uploadEndpoint = baseURL.appendingPathComponent("/api/user-files/upload-file/")
        var req = try authedRequest(uploadEndpoint, method: "POST")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BaserowError.http(0, "Bad upload response")
        }
        return json
    }

    /// Creates a row for an episode. Field names must match the Baserow table
    /// (see Settings > Baserow Sync for the exact schema Relay expects).
    /// Callers should store the returned row id (`EpisodeDraft.baserowRowId`)
    /// and use `updateEpisodeRow` on subsequent syncs instead of calling this
    /// again, or every re-sync creates a duplicate row.
    func createEpisodeRow(draft: EpisodeDraft, recording: Recording, uploadedFile: [String: Any]?) async throws -> Int {
        var req = try authedRequest(rowsEndpoint(), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: fields(draft: draft, recording: recording, uploadedFile: uploadedFile))

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            throw BaserowError.http(0, "Bad row response")
        }
        return id
    }

    /// Updates an existing row in place (created by a prior `createEpisodeRow`
    /// call), so re-syncing the same episode doesn't create a duplicate.
    func updateEpisodeRow(rowId: Int, draft: EpisodeDraft, recording: Recording, uploadedFile: [String: Any]?) async throws {
        var req = try authedRequest(rowsEndpoint(rowId: rowId), method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: fields(draft: draft, recording: recording, uploadedFile: uploadedFile))

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
    }

    private func rowsEndpoint(rowId: Int? = nil) -> URL {
        var path = "/api/database/rows/table/\(tableId)/"
        if let rowId { path += "\(rowId)/" }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_field_names", value: "true")]
        return components.url!
    }

    private func fields(draft: EpisodeDraft, recording: Recording, uploadedFile: [String: Any]?) -> [String: Any] {
        var fields: [String: Any] = [
            "Title": draft.title,
            "Show": draft.showTitle ?? "",
            "Summary": draft.summary,
            "Description": draft.description,
            "Explicit": draft.explicit,
            "Season": draft.season,
            "Episode Number": draft.number,
            "Status": draft.status.rawValue,
            "Recorded At": ISO8601DateFormatter().string(from: recording.createdAt),
            "Duration Seconds": Int(recording.duration),
            "Transistor Episode ID": draft.transistorEpisodeId ?? ""
        ]
        if let uploadedFile {
            fields["Audio File"] = [uploadedFile]
        }
        return fields
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BaserowError.http(http.statusCode, body)
        }
    }
}
