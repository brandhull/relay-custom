import Foundation

// Craft's Connect API is capability-URL authenticated: the user creates an
// "All Documents" (space-wide) API connection from Craft's app
// (Connections tab), and Craft hands back a unique base URL that itself
// grants access — no separate token/header needed. See connect.craft.do/api-docs.
//
// Pushing a voice note as a new entry in a folder (e.g. "Voicenotes") is a
// two-step flow: create a document with that folder as its destination,
// then insert the transcript/summary as a block into the new document.
enum CraftError: LocalizedError {
    case missingConfig
    case http(Int, String)
    case noDocumentReturned
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig: return "Add your Craft API URL and pick a folder in Settings first."
        case .http(let code, let msg): return "Craft error \(code): \(msg)"
        case .noDocumentReturned: return "Craft didn't return the new document."
        case .unexpectedResponse(let body):
            let trimmed = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "Craft returned something Relay didn't expect: \(trimmed)"
        }
    }
}

struct CraftFolder: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var documentCount: Int? = nil
    var folders: [CraftFolder]? = nil

    /// Flattens the folder tree into a simple pick list, indenting nested
    /// folders so the hierarchy is still visible.
    static func flatten(_ folders: [CraftFolder], depth: Int = 0) -> [(folder: CraftFolder, depth: Int)] {
        folders.flatMap { folder -> [(CraftFolder, Int)] in
            [(folder, depth)] + flatten(folder.folders ?? [], depth: depth + 1)
        }
    }
}

struct CraftAPI {
    var baseURL: URL

    func listFolders() async throws -> [CraftFolder] {
        let url = baseURL.appendingPathComponent("folders")
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.checkStatus(response, data: data)
        do {
            return try JSONDecoder().decode(FoldersResponse.self, from: data).items
        } catch {
            throw CraftError.unexpectedResponse(String(data: data, encoding: .utf8) ?? error.localizedDescription)
        }
    }

    /// Creates a new document inside the given folder, returning its id.
    func createDocument(title: String, folderId: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("documents"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "documents": [["title": title]],
            "destination": ["folderId": folderId]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
        do {
            let decoded = try JSONDecoder().decode(DocumentsResponse.self, from: data)
            guard let id = decoded.items.first?.id else { throw CraftError.noDocumentReturned }
            return id
        } catch let error as CraftError {
            throw error
        } catch {
            throw CraftError.unexpectedResponse(String(data: data, encoding: .utf8) ?? error.localizedDescription)
        }
    }

    /// Appends a markdown text block to the end of the given document.
    func insertMarkdown(_ markdown: String, intoDocument pageId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("blocks"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "blocks": [[
                "type": "text",
                "markdown": markdown
            ]],
            "position": ["pageId": pageId, "position": "end"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(response, data: data)
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CraftError.http(http.statusCode, body)
        }
    }
}

private struct FoldersResponse: Decodable {
    let items: [CraftFolder]
}

private struct DocumentsResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let title: String?
    }
    let items: [Item]
}
