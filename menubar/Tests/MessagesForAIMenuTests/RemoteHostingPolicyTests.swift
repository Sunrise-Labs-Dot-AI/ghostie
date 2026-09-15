import XCTest
@testable import MessagesForAIMenu

final class RemoteHostingPolicyTests: XCTestCase {
  func testHTTPSOriginOnly() {
    XCTAssertNotNil(RemoteHostingPolicy.origin("https://relay.example.test"))
    XCTAssertNotNil(RemoteHostingPolicy.origin("https://relay.example.test:443/"))
    for value in ["http://relay.example.test", "file:///tmp/host", "https://user:secret@relay.example.test", "https://relay.example.test/path", "https://relay.example.test?token=secret", "https://relay.example.test#secret", "not a URL"] {
      XCTAssertNil(RemoteHostingPolicy.origin(value), value)
    }
  }
  func testURLSafeCredentialEncodingAndHostResource() {
    let encoded = RemoteHostingPolicy.base64URL(Data(repeating: 255, count: 32))
    XCTAssertEqual(encoded.count, 43)
    XCTAssertFalse(encoded.contains("="))
    XCTAssertFalse(encoded.contains("/"))
    let value = RemoteHostCredential(origin: "https://relay.example.test", host: "host-a", user: "user-a", credential: "secret")
    XCTAssertEqual(value.mcpURL, "https://relay.example.test/mcp/hosts/host-a")
    XCTAssertFalse(value.mcpURL.contains("secret"))
  }
}

@MainActor
final class RemoteHostingLifecycleTests: XCTestCase {
  private func fixture(backend: URL, request: ((URLRequest) async throws -> [String: Any])? = nil,
                       remove: (() -> Void)? = nil) -> (RemoteHostingController, UserDefaults) {
    let defaults = UserDefaults(suiteName: "remote-host-test-\(UUID().uuidString)")!
    let account = RemoteHostCredential(origin: "https://relay.example.test", host: String(repeating: "A", count: 43), user: "user-fixture", credential: String(repeating: "B", count: 43))
    return (RemoteHostingController(account: account, defaults: defaults, backendURL: backend, requestOverride: request, removeCredential: remove), defaults)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("State transition did not complete")
  }

  func testStartStopAndQuitPreference() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture-host")
    try "#!/bin/sh\nwhile IFS= read -r line; do echo '{\"status\":\"online\"}'; done\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let (controller, defaults) = fixture(backend: executable)
    controller.startHosting()
    XCTAssertTrue(controller.isHosting)
    try await waitFor { controller.status.hasPrefix("Online") }
    controller.stopHosting(preservePreference: true)
    XCTAssertFalse(controller.isHosting)
    XCTAssertTrue(defaults.bool(forKey: "remoteHostingEnabled"))
    controller.startHosting()
    XCTAssertTrue(controller.isHosting)
    controller.stopHosting()
    XCTAssertFalse(defaults.bool(forKey: "remoteHostingEnabled"))
  }

  func testMissingAndFailedProcessStayOffline() async throws {
    let (missing, defaults) = fixture(backend: URL(fileURLWithPath: "/no-such-fixture-host"))
    missing.startHosting()
    XCTAssertFalse(missing.isHosting)
    XCTAssertFalse(defaults.bool(forKey: "remoteHostingEnabled"))
    let (failed, _) = fixture(backend: URL(fileURLWithPath: "/usr/bin/false"))
    failed.startHosting()
    try await waitFor { !failed.isHosting }
  }

  func testDisconnectRevokesBeforeDeletingKeychainCredential() async throws {
    var removed = false
    let (controller, _) = fixture(backend: URL(fileURLWithPath: "/no-such-fixture-host"), request: { request in
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertTrue(request.url!.path.hasPrefix("/hosts/"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "B", count: 43))
      XCTAssertFalse(removed)
      return ["ok": true]
    }, remove: { removed = true })
    controller.disconnectAccount()
    try await waitFor { !controller.isDisconnecting }
    XCTAssertTrue(removed)
    XCTAssertNil(controller.account)
  }

  func testFailedRevocationRetainsCredentialForRetryAndDisablesHosting() async throws {
    let (controller, _) = fixture(backend: URL(fileURLWithPath: "/no-such-fixture-host"), request: { _ in
      throw URLError(.notConnectedToInternet)
    }, remove: { XCTFail("Must retain the credential to retry revocation") })
    controller.disconnectAccount()
    controller.startHosting()
    XCTAssertFalse(controller.isHosting)
    try await waitFor { !controller.isDisconnecting }
    XCTAssertNotNil(controller.account)
    XCTAssertTrue(controller.status.contains("try Disconnect again"))
  }

  func testCancelDuringPairStartCannotOpenBrowserOrRestorePairing() async throws {
    var pendingStart: CheckedContinuation<[String: Any], Error>?
    var cancelled = false
    let defaults = UserDefaults(suiteName: "remote-pair-test-\(UUID().uuidString)")!
    let controller = RemoteHostingController(account: nil, defaults: defaults, requestOverride: { request in
      if request.url!.path == "/api/pair/start" {
        return try await withCheckedThrowingContinuation { pendingStart = $0 }
      }
      XCTAssertEqual(request.url!.path, "/api/pair/cancel")
      cancelled = true
      throw URLError(.notConnectedToInternet)
    })
    controller.relayOrigin = "https://relay.example.test"
    controller.createAccountOrSignIn()
    try await waitFor { pendingStart != nil }
    controller.cancelPairing()
    pendingStart?.resume(returning: ["id": "fixture-pair", "code": "ABCDEFGH", "url": "https://relay.example.test/pair?id=fixture-pair"])
    try await waitFor { cancelled && controller.status.contains("could not confirm") }
    XCTAssertFalse(controller.isPairing)
    XCTAssertNil(controller.pairingURL)
    XCTAssertNil(controller.account)
  }
}
