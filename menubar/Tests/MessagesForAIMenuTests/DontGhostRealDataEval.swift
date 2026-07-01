import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Opt-in real-data harness for the deterministic vs AI comparison. Reads the
/// actual chat.db candidate universe (the same scan production runs), records
/// the deterministic surface decision + confidence per thread, and writes a
/// review sample to /tmp/dg-real-eval/. The AI decision is added in a separate
/// step (the production classify prompt) so the three approaches can be compared:
///   • deterministic only  = det_surface
///   • AI only             = ai_surface
///   • deterministic + AI  = det_surface AND ai_surface
///
/// Gated behind DG_REAL_EVAL=1 so it NEVER runs in normal `swift test` (it reads
/// private message content and needs Full Disk Access). Run explicitly:
///   DG_REAL_EVAL=1 swift test --filter DontGhostRealDataEval
///
/// WhatsApp note: bodies are encrypted at rest (#81), so WhatsApp candidates now
/// load through the daemon's decrypt-on-read RPC rather than reading messages.db
/// directly. A reachable WhatsApp daemon is required for WhatsApp threads to
/// appear here; the daemon enforces peer-auth, so an unsigned test binary only
/// connects against a dev-mode daemon (WHATSAPP_MCP_DEV=1). Without one, the
/// eval simply shows no WhatsApp rows (never the old byte-garbage).
final class DontGhostRealDataEval: XCTestCase {
  func test_dumpRealCandidates() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["DG_REAL_EVAL"] == "1",
                      "opt-in: set DG_REAL_EVAL=1 to run the real-data eval")

    // Universe = every gate-passing candidate (business/relationship/age/kind
    // gates applied, but NOT the deterministic surface gate). This is exactly
    // the set the AI judges in production.
    let universe = try DontGhostScanner.loadCandidates(aiEnabled: true)
    // Deterministic-surfaced subset (the surface gate applied).
    let detSurfacedIDs = Set(try DontGhostScanner.loadCandidates(aiEnabled: false).map(\.id))

    // Most-recent N for a manageable review + AI-labeling sample.
    let sampleLimit = Int(ProcessInfo.processInfo.environment["DG_REAL_EVAL_LIMIT"] ?? "") ?? 60
    let sample = universe
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
      .prefix(sampleLimit)

    let owed = universe.filter { $0.kind == .owedReply }.count
    let follow = universe.filter { $0.kind == .followUp }.count
    print("REAL_EVAL universe=\(universe.count) det_surfaced=\(detSurfacedIDs.count) owed=\(owed) follow=\(follow) sample=\(sample.count)")

    let now = Date()
    var rows: [[String: Any]] = []
    for s in sample {
      // Up to 16 most-recent messages for context (direction + age + body).
      let tail = s.messages.suffix(16).map { m -> [String: Any] in
        let daysAgo = Int((now.timeIntervalSince(m.sentAt) / 86_400).rounded())
        return ["from": m.fromMe ? "me" : "them", "days_ago": daysAgo, "body": m.body]
      }
      rows.append([
        "id": s.id,
        "kind": s.kind == .owedReply ? "owed_reply" : "follow_up",
        "person": s.displayName,
        "det_surface": detSurfacedIDs.contains(s.id),
        "det_confidence": (s.confidence * 1000).rounded() / 1000,
        "det_reason": s.reason,
        "last_message_at": DontGhostController.iso(s.lastMessageAt),
        "last_message_days_ago": Int((now.timeIntervalSince(s.lastMessageAt) / 86_400).rounded()),
        "msg_count": s.messages.count,
        "messages": tail,
      ])
    }

    let dir = URL(fileURLWithPath: "/tmp/dg-real-eval")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    let out = dir.appendingPathComponent("candidates.json")
    try data.write(to: out)
    print("REAL_EVAL wrote \(rows.count) rows → \(out.path)")
  }
}
