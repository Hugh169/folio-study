import Foundation

/// Sends requests to Anthropic's Messages API with the student's own key, and
/// reads what comes back, for sorting and for writing flashcards. Swift has no
/// official Anthropic SDK, so this sends the JSON shapes Anthropic documents.
enum ClaudeAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct Response {
        var data: Data
        var status: Int
    }

    /// Sends `body`. When Claude is busy or rate limited, waits as long as
    /// Anthropic asks, up to 20 seconds, and tries again up to `retries` times.
    /// Throws only when Anthropic can't be reached.
    static func send(_ body: Data, key: String, session: URLSession, retries: Int = 1, timeout: TimeInterval = 60) async throws -> Response {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if retries > 0, [429, 500, 503, 504, 529].contains(status) {
            let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 3
            try? await Task.sleep(for: .seconds(min(max(wait, 1), 20)))
            return try await send(body, key: key, session: session, retries: retries - 1, timeout: timeout)
        }
        return Response(data: data, status: status)
    }

    /// What a response other than 200 means, with Anthropic's own message.
    static func problem(status: Int, json: [String: Any]?) -> (ClaudeVoter.Problem, String) {
        let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
        let isAboutMoney = ["credit", "billing", "spend limit", "usage limit"].contains { message.localizedCaseInsensitiveContains($0) }
        let problem: ClaudeVoter.Problem = switch status {
        case 401: .badKey
        case 402: .billing(message)
        case 429: .rateLimited
        case 400 where isAboutMoney: .billing(message)
        case 400..<500: .rejected(message)
        default: .unavailable(message)
        }
        return (problem, message)
    }

    /// The tokens a request used, as the response reports them.
    static func usage(in json: [String: Any]) -> (input: Int, output: Int)? {
        (json["usage"] as? [String: Any]).map { (input: $0["input_tokens"] as? Int ?? 0, output: $0["output_tokens"] as? Int ?? 0) }
    }

    /// The answer: the text block, which thinking blocks can come before.
    static func text(in json: [String: Any]) -> String? {
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    }
}
