import Foundation

/// Where the premium/account backend lives. Production is messagesfor.ai;
/// dev/staging builds can point at a Vercel preview deployment with
///   defaults write com.sunriselabs.messages-for-ai premiumBaseURL https://…
/// so Clerk/Stripe test-mode flows never touch production data.
enum PremiumEndpoints {
  static var baseURL: URL {
    if let override = UserDefaults.standard.string(forKey: "premiumBaseURL"),
       let url = URL(string: override), url.scheme == "https" {
      return url
    }
    return URL(string: "https://messagesfor.ai")!
  }

  static func api(_ path: String, query: [URLQueryItem] = []) -> URL? {
    var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    if !query.isEmpty { components?.queryItems = query }
    return components?.url
  }
}

/// Free-trial model calls on the house key, metered per account server-side
/// (site/api/ai-proxy.js). Labs use this only when the user has no key of
/// their own: BYOK always wins, premium subscribers get unmetered access.
enum HouseProxyClient {
  struct Completion {
    let text: String
    /// Free calls left for this tool, nil when the account is premium.
    let remaining: Int?
  }

  enum ProxyError: LocalizedError {
    case notSignedIn
    case freeCallsExhausted
    case server(String)

    var errorDescription: String? {
      switch self {
      case .notSignedIn:
        return "Sign in (Settings → Account) to try this free, or add your own API key."
      case .freeCallsExhausted:
        return "Your free tries for this feature are used up — subscribe to keep going, or add your own API key."
      case .server(let message):
        return message
      }
    }
  }

  /// The Clerk session token captured at sign-in. Short-lived by default —
  /// the account site issues a longer-lived "mac-app" JWT template token
  /// once that template exists in Clerk.
  static func storedToken() -> String? {
    let url = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("entitlement.json")
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(Entitlement.self, from: data) else { return nil }
    return decoded.token?.isEmpty == false ? decoded.token : nil
  }

  static func complete(
    tool: AILab,
    prompt: String,
    system: String? = nil,
    maxTokens: Int? = nil
  ) async throws -> Completion {
    guard let token = storedToken() else { throw ProxyError.notSignedIn }
    guard let url = PremiumEndpoints.api("api/ai-proxy") else { throw ProxyError.server("Bad endpoint.") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    var body: [String: Any] = ["tool": tool.rawValue, "prompt": prompt]
    if let system { body["system"] = system }
    if let maxTokens { body["max_tokens"] = maxTokens }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    switch status {
    case 200..<300:
      return Completion(
        text: root["text"] as? String ?? "",
        remaining: root["remaining"] as? Int
      )
    case 401:
      throw ProxyError.notSignedIn
    case 402:
      throw ProxyError.freeCallsExhausted
    default:
      throw ProxyError.server(root["error"] as? String ?? "Trial call failed (\(status)).")
    }
  }
}
