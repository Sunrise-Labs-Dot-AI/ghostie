import AppKit
import CryptoKit
import Foundation
import Security

struct RemoteHostCredential: Codable, Equatable {
  let origin: String
  let host: String
  let user: String
  let credential: String
  var mcpURL: String { "\(origin)/mcp/hosts/\(host)" }
}

enum RemoteHostingPolicy {
  static func origin(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
    return url
  }
  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

private enum RemoteCredentialStore {
  static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "com.sunriselabs.messages-for-ai.remote-host", kSecAttrAccount as String: "host"]
  }
  static func load() -> RemoteHostCredential? {
    var lookup = query
    lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(RemoteHostCredential.self, from: data)
  }
  static func save(_ value: RemoteHostCredential) throws {
    let data = try JSONEncoder().encode(value)
    let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw RemoteHostingError.unavailable }
    var add = query
    add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw RemoteHostingError.unavailable }
  }
  static func remove() { SecItemDelete(query as CFDictionary) }
}
private enum RemoteHostingError: Error { case unavailable }
private final class RemoteRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class RemoteHostingController: ObservableObject {
  static let shared = RemoteHostingController(account: RemoteCredentialStore.load(), defaults: .standard)
  @Published var relayOrigin: String
  @Published private(set) var account: RemoteHostCredential?
  @Published private(set) var status = "Off"
  @Published private(set) var pairingCode: String?
  @Published private(set) var pairingURL: URL?
  @Published private(set) var isPairing = false
  @Published private(set) var isHosting = false
  @Published private(set) var isDisconnecting = false
  private var process: Process?
  private var input: Pipe?
  private var output: Pipe?
  private var outputBuffer = Data()
  private var pairingTask: Task<Void, Never>?
  private var pairingID: String?
  private var pairingSecret: String?
  private var generation = UUID()
  private let defaults: UserDefaults
  private let backendURL: URL?
  private let requestOverride: ((URLRequest) async throws -> [String: Any])?
  private let removeCredential: () -> Void
  private let session = URLSession(configuration: .ephemeral, delegate: RemoteRedirectPolicy(), delegateQueue: nil)

  init(account saved: RemoteHostCredential?, defaults: UserDefaults, backendURL: URL? = nil,
       requestOverride: ((URLRequest) async throws -> [String: Any])? = nil, removeCredential: (() -> Void)? = nil) {
    self.defaults = defaults; self.backendURL = backendURL; self.requestOverride = requestOverride
    self.removeCredential = removeCredential ?? RemoteCredentialStore.remove
    account = saved
    relayOrigin = saved?.origin ?? (Bundle.main.object(forInfoDictionaryKey: "GhostieRemoteRelayURL") as? String)
      ?? ProcessInfo.processInfo.environment["GHOSTIE_RELAY_ORIGIN"] ?? ""
    if saved != nil { status = "Connected account. Hosting is off." }
  }
  func resumeIfEnabled() {
    guard !AppStoragePaths.isUsingHomeOverride, defaults.bool(forKey: "remoteHostingEnabled") else { return }
    startHosting()
  }
  private func request(_ path: String, origin: String, body: [String: String] = [:], credential: String? = nil,
                       method: String = "POST") async throws -> [String: Any] {
    guard let base = RemoteHostingPolicy.origin(origin), let url = URL(string: path, relativeTo: base)?.absoluteURL,
          url.host == base.host, url.scheme == "https" else { throw RemoteHostingError.unavailable }
    var request = URLRequest(url: url)
    request.httpMethod = method; request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    if let requestOverride { return try await requestOverride(request) }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 16_384,
          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteHostingError.unavailable }
    return result
  }
  func createAccountOrSignIn() {
    guard account == nil, !isPairing, let url = RemoteHostingPolicy.origin(relayOrigin) else { return }
    let origin = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { status = "Secure pairing is unavailable."; return }
    let secret = RemoteHostingPolicy.base64URL(Data(bytes))
    let digest = RemoteHostingPolicy.base64URL(Data(SHA256.hash(data: Data(secret.utf8))))
    let current = UUID(); generation = current
    isPairing = true; status = "Opening secure sign-in..."; pairingSecret = secret
    pairingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let start = try await request("/api/pair/start", origin: origin, body: ["digest": digest])
        guard let id = start["id"] as? String, let code = start["code"] as? String,
              let urlString = start["url"] as? String, let browserURL = URL(string: urlString),
              browserURL.scheme == "https", browserURL.host == url.host, browserURL.port == url.port,
              browserURL.path == "/pair" else { throw RemoteHostingError.unavailable }
        guard generation == current, !Task.isCancelled else {
          let cancelledGeneration = generation
          do { _ = try await request("/api/pair/cancel", origin: origin, body: ["id": id], credential: secret) }
          catch {
            if generation == cancelledGeneration && !isPairing {
              status = "Cancelled locally. The service could not confirm cancellation; the browser pairing expires within five minutes."
            }
          }
          return
        }
        pairingID = id; pairingCode = code; pairingURL = browserURL
        status = "Enter this code in the browser, then return here."
        NSWorkspace.shared.open(browserURL)
        let expiry = Date().addingTimeInterval(300)
        while Date() < expiry && !Task.isCancelled {
          try await Task.sleep(nanoseconds: 2_000_000_000)
          let result = try await request("/api/pair/poll", origin: origin, body: ["id": id], credential: secret)
          guard generation == current, !Task.isCancelled else { return }
          if result["status"] as? String == "paired", let host = result["host"] as? String, let user = result["user"] as? String,
             host.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil {
            let account = RemoteHostCredential(origin: origin, host: host, user: user, credential: secret)
            try RemoteCredentialStore.save(account)
            self.account = account; relayOrigin = origin
            pairingID = nil; pairingSecret = nil; pairingCode = nil; pairingURL = nil; isPairing = false
            status = "Account connected. Choose Start hosting when ready."; return
          }
        }
        throw RemoteHostingError.unavailable
      } catch {
        guard generation == current else { return }
        if let id = pairingID { _ = try? await request("/api/pair/cancel", origin: origin, body: ["id": id], credential: secret) }
        guard generation == current else { return }
        isPairing = false; pairingCode = nil; pairingURL = nil; pairingID = nil; pairingSecret = nil
        status = "Pairing expired or the service is unavailable. Try again."
      }
    }
  }
  func cancelPairing() {
    generation = UUID(); pairingTask?.cancel(); pairingTask = nil
    let current = generation
    if let id = pairingID, let secret = pairingSecret {
      let origin = relayOrigin
      Task {
        do {
          _ = try await request("/api/pair/cancel", origin: origin, body: ["id": id], credential: secret)
          if generation == current { status = "Pairing cancelled." }
        } catch {
          if generation == current { status = "Cancelled locally. The service could not confirm cancellation; the browser pairing expires within five minutes." }
        }
      }
    }
    pairingID = nil; pairingSecret = nil; pairingCode = nil; pairingURL = nil; isPairing = false; status = "Off"
  }
  func startHosting() {
    guard !isDisconnecting, process == nil, let account, RemoteHostingPolicy.origin(account.origin) != nil else { return }
    let executable = backendURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/messages-for-ai-backend")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      status = "This build does not include the remote host. Install a configured Ghostie build."; return
    }
    let child = Process(), input = Pipe(), output = Pipe()
    child.executableURL = executable; child.arguments = ["ghostie-remote-host"]
    child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
    child.terminationHandler = { [weak self] child in
      Task { @MainActor in
        guard let self, self.process === child else { return }
        self.stopHosting(); self.status = "Host stopped. Choose Start hosting to reconnect."
      }
    }
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor in
        guard let self, self.process === child else { return }
        self.outputBuffer.append(data)
        guard self.outputBuffer.count <= 8192 else { self.stopHosting(); return }
        while let newline = self.outputBuffer.firstIndex(of: 10) {
          let line = self.outputBuffer.prefix(upTo: newline)
          self.outputBuffer.removeSubrange(...newline)
          if let result = try? JSONSerialization.jsonObject(with: line) as? [String: String] {
            switch result["status"] {
            case "online": self.status = "Online. Read and draft-only access is available."
            case "offline": self.status = "Offline. Reconnecting while Ghostie stays open..."
            default: self.status = "Host unavailable. Stop hosting and reconnect."
            }
          }
        }
      }
    }
    do {
      self.process = child; self.input = input; self.output = output
      try child.run()
      let config = ["origin": account.origin, "host": account.host, "credential": account.credential]
      var data = try JSONSerialization.data(withJSONObject: config); data.append(10)
      try input.fileHandleForWriting.write(contentsOf: data)
      isHosting = true; status = "Connecting..."; defaults.set(true, forKey: "remoteHostingEnabled")
    } catch { stopHosting(); status = "Could not start the local host." }
  }
  func stopHosting(preservePreference: Bool = false) {
    output?.fileHandleForReading.readabilityHandler = nil
    try? input?.fileHandleForWriting.close()
    if let process, process.isRunning { process.terminate() }
    process = nil; input = nil; output = nil; outputBuffer = Data(); isHosting = false
    if !preservePreference { defaults.set(false, forKey: "remoteHostingEnabled") }
    status = "Off. Remote clients cannot reach this Mac."
  }
  func disconnectAccount() {
    guard !isDisconnecting else { return }
    stopHosting()
    guard let account else { return }
    isDisconnecting = true; status = "Revoking remote access..."
    Task {
      defer { isDisconnecting = false }
      do {
        _ = try await request("/hosts/\(account.host)", origin: account.origin, credential: account.credential, method: "DELETE")
        removeCredential(); self.account = nil; status = "Disconnected. Remote access has been revoked."
      } catch { status = "Hosting is off. Reconnect to the internet and try Disconnect again to revoke the account connection." }
    }
  }
}
