import Foundation

struct CreatedRemoteRoom: Decodable, Sendable {
    let roomCode: String
    let hostToken: String
}

struct RemoteComment: Decodable, Identifiable, Sendable {
    let id: Int64
    let content: String
    let createdAt: String?
}

enum RemoteCommentServiceError: LocalizedError {
    case invalidSupabaseURL
    case emptyResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSupabaseURL:
            return "Invalid Supabase URL"
        case .emptyResponse:
            return "Supabase returned an empty response"
        case .requestFailed(let message):
            return message
        }
    }
}

final class RemoteCommentService: @unchecked Sendable {
    func createRoom(
        supabaseURL: String,
        anonKey: String,
        adminToken: String
    ) async throws -> CreatedRemoteRoom {
        let body = CreateRoomRequest(pAdminToken: adminToken)
        let rooms: [CreatedRemoteRoom] = try await postRPC(
            supabaseURL: supabaseURL,
            anonKey: anonKey,
            functionName: "create_room",
            body: body
        )
        guard let room = rooms.first else { throw RemoteCommentServiceError.emptyResponse }
        return room
    }

    func fetchComments(
        supabaseURL: String,
        anonKey: String,
        roomCode: String,
        hostToken: String,
        afterID: Int64
    ) async throws -> [RemoteComment] {
        let body = FetchCommentsRequest(
            pRoomCode: roomCode,
            pHostToken: hostToken,
            pAfterId: afterID
        )
        return try await postRPC(
            supabaseURL: supabaseURL,
            anonKey: anonKey,
            functionName: "fetch_room_comments",
            body: body
        )
    }

    private func postRPC<Response: Decodable, Body: Encodable>(
        supabaseURL: String,
        anonKey: String,
        functionName: String,
        body: Body
    ) async throws -> Response {
        let normalizedBaseURL = supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(normalizedBaseURL)/rest/v1/rpc/\(functionName)") else {
            throw RemoteCommentServiceError.invalidSupabaseURL
        }

        let apiKey = normalizeSupabaseAPIKey(anonKey)
        guard !apiKey.isEmpty else {
            throw RemoteCommentServiceError.requestFailed("Supabase anon key is empty")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let message = decodeErrorMessage(from: data)
            throw RemoteCommentServiceError.requestFailed(message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    private func decodeErrorMessage(from data: Data) -> String {
        if let error = try? JSONDecoder().decode(SupabaseRPCError.self, from: data) {
            return error.message
        }
        return String(data: data, encoding: .utf8) ?? "Supabase request failed"
    }

    private func normalizeSupabaseAPIKey(_ value: String) -> String {
        let tokens = value
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let jwt = tokens.first(where: { $0.hasPrefix("eyJ") }) {
            return jwt
        }
        if let publishable = tokens.first(where: { $0.hasPrefix("sb_publishable_") }) {
            return publishable
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CreateRoomRequest: Encodable {
    let pAdminToken: String
}

private struct FetchCommentsRequest: Encodable {
    let pRoomCode: String
    let pHostToken: String
    let pAfterId: Int64
}

private struct SupabaseRPCError: Decodable {
    let message: String
}
