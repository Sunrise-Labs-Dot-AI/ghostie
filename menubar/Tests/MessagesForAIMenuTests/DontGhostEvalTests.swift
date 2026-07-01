import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Behavioral eval for the deterministic Don't Ghost scorer. A labeled set of
/// conversation tails (ground truth = should a thoughtful person surface this
/// thread) is scored by `scoreCandidate`; the harness prints precision / recall
/// / F1 / accuracy plus the false-positive and false-negative ids so we can
/// compare against the LLM-in-the-loop baseline and iterate.
///
/// Run: `swift test --filter DontGhostEvalTests` and read the `EVAL_*` lines.
/// It also writes the fixtures (without labels) + a truth map to /tmp/dg-eval/
/// so the LLM baseline pass can label the identical set with the production
/// classify prompt.
final class DontGhostEvalTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  struct EvalCase {
    let id: Int
    let kind: DontGhostKind
    let saved: Bool
    let truth: Bool
    let note: String
    let msgs: [(fromMe: Bool, body: String, daysAgo: Double)] // oldest → newest
  }

  /// Generate a follow-up thread: `count` messages spread over `span` days,
  /// ending `last` days ago with YOU sending last. `oneWay` makes it a near
  /// one-way blast (a single prior inbound); otherwise it alternates (balanced).
  private static func genFollow(count: Int, oneWay: Bool, span: Double, last: Double) -> [(Bool, String, Double)] {
    var out: [(Bool, String, Double)] = []
    for i in 0..<count {
      let frac = count == 1 ? 0 : Double(i) / Double(count - 1)
      let daysAgo = last + span * (1 - frac)
      let fromMe = oneWay ? (i != 0) : (i % 2 == 1)
      out.append((fromMe, "thread message \(i)", daysAgo))
    }
    out[count - 1].0 = true // follow-up = you sent last
    return out
  }

  private static func cases() -> [EvalCase] {
    var c: [EvalCase] = []
    func owed(_ id: Int, _ truth: Bool, _ note: String, _ msgs: [(Bool, String, Double)], saved: Bool = true) {
      c.append(EvalCase(id: id, kind: .owedReply, saved: saved, truth: truth, note: note, msgs: msgs))
    }
    func follow(_ id: Int, _ truth: Bool, _ note: String, count: Int, oneWay: Bool, span: Double, last: Double, saved: Bool = true) {
      c.append(EvalCase(id: id, kind: .followUp, saved: saved, truth: truth, note: note, msgs: genFollow(count: count, oneWay: oneWay, span: span, last: last)))
    }

    // ── OWED REPLY — should surface (a thoughtful person would still reply) ──
    owed(1, true, "direct question", [(true, "hey", 2), (false, "you around this weekend?", 1)])
    owed(2, true, "interrogative, no ?", [(true, "let's meet", 3), (false, "what time works for you on thursday", 1)])
    owed(3, true, "explicit ask", [(true, "omw", 3), (false, "can you send me the address when you get a sec", 1)])
    owed(4, true, "invitation", [(true, "hey!", 3), (false, "wanna grab dinner friday?", 1)])
    owed(5, true, "emotional bid", [(true, "hey stranger", 10), (false, "miss you! how have you been?", 2)])
    owed(6, true, "interrogative no ?", [(true, "any news?", 5), (false, "did you ever hear back from the landlord", 1)])
    owed(7, true, "ask/plan", [(true, "planning", 4), (false, "let me know if saturday works for you", 1)])
    owed(8, true, "reconnect invite", [(true, "hi!", 6), (false, "hey it's been forever, we should catch up soon", 2)])
    owed(9, true, "invitation no ?", [(true, "hi", 8), (false, "i'm in town next week if you're free", 2)])
    owed(10, true, "celebratory update, no cue", [(true, "good luck!", 4), (false, "i got the job!!!", 1)])
    owed(11, true, "update inviting response", [(true, "plan?", 3), (false, "ok so i talked to mom and she said it's fine for us to come", 1)])
    owed(12, true, "multiple unanswered", [(true, "hey", 2), (false, "you free tomorrow?", 1), (false, "or sunday works too", 1)])
    owed(13, true, "emotional bid + emoji", [(true, "hey", 5), (false, "thinking about you today ❤️", 2)])

    // ── OWED REPLY — should NOT surface (ack / closer / complete) ──
    owed(14, false, "pure ack", [(true, "see you at 7", 2), (false, "ok", 1)])
    owed(15, false, "closer compound", [(true, "7pm?", 2), (false, "sounds good, see you then", 1)])
    owed(16, false, "thanks + emoji", [(true, "sent it", 2), (false, "thanks so much 🙏", 1)])
    owed(17, false, "emoji only", [(true, "good?", 2), (false, "👍", 1)])
    owed(18, false, "laughter ack", [(true, "funny right", 2), (false, "haha yeah", 1)])
    owed(19, false, "tapback", [(true, "pic", 2), (false, "Loved an image", 1)])
    owed(20, false, "closer", [(true, "ok", 2), (false, "perfect, talk soon", 1)])
    owed(21, false, "ack", [(true, "sorry late", 2), (false, "no worries, thanks!", 1)])
    owed(22, false, "closer compound", [(true, "can you grab milk", 2), (false, "got it, will do", 1)])
    owed(23, false, "ack", [(true, "moved to 8", 2), (false, "cool", 1)])
    // Adversarial precision cases (deterministic likely over-surfaces at first):
    owed(24, false, "reaction-complete", [(true, "meme", 2), (false, "lol that's hilarious", 1)])
    owed(25, false, "logistic closer", [(true, "9am still good?", 2), (false, "see you tomorrow!", 1)])
    owed(26, false, "logistics complete", [(true, "where again?", 2), (false, "address is 123 main st, 7pm", 1)])
    owed(27, false, "status complete", [(true, "here?", 1), (false, "on my way", 0.5)])
    owed(28, false, "first-person 'i'll let you know'", [(true, "good luck tmrw", 2), (false, "thanks, that really helped. i'll let you know how it goes", 1)])
    owed(29, false, "status complete", [(true, "you close?", 1), (false, "omw, running 5 late", 0.5)])

    // ── FOLLOW-UP — should surface (welcome reconnect, higher bar) ──
    follow(30, true, "close friend, quiet 25d", count: 12, oneWay: false, span: 40, last: 25)
    follow(31, true, "close, quiet 18d", count: 10, oneWay: false, span: 30, last: 18)
    follow(32, true, "STRONG UNSAVED quiet 25d", count: 12, oneWay: false, span: 40, last: 25, saved: false)
    follow(33, true, "very close, quiet 30d", count: 14, oneWay: false, span: 50, last: 30)
    follow(34, true, "chatty pair quiet 14d", count: 8, oneWay: false, span: 20, last: 14)

    // ── FOLLOW-UP — should NOT surface ──
    follow(35, false, "one-way blast", count: 6, oneWay: true, span: 30, last: 60, saved: false)
    follow(36, false, "thin relationship (saved)", count: 4, oneWay: false, span: 20, last: 40)
    follow(37, false, "sparse pair, too soon (cadence)", count: 5, oneWay: false, span: 120, last: 10)
    follow(38, false, "weak, out of the blue", count: 4, oneWay: true, span: 10, last: 90, saved: false)
    c.append(EvalCase(id: 39, kind: .followUp, saved: true, truth: false, note: "already nagged (trailing outbound run)",
                      msgs: [(false, "hey", 30), (true, "hi!", 29), (true, "you free this week?", 20), (true, "hello?", 16)]))

    // ── HELD-OUT (ids 40+): NOT tuned against; probes the precision rules for
    //    over-suppression (laughter/status/see-you/logistics firing on real asks)
    //    and confirms recall + cadence hold on unseen patterns. ──
    owed(40, true, "laughter opener but real ask", [(true, "sent a meme", 1), (false, "lol no but for real can you send it?", 0.5)])
    owed(41, true, "status + real ask compound", [(true, "you here?", 1), (false, "on my way! can you unlock the door?", 0.5)])
    owed(42, true, "laughter + question", [(true, "how'd it go", 1), (false, "haha that's great, what did she say?", 0.5)])
    owed(43, false, "pure laughter", [(true, "funny?", 1), (false, "haha", 0.5)])
    owed(44, false, "status omw", [(true, "where are you", 1), (false, "omw", 0.5)])
    owed(45, false, "stacked ack", [(true, "good?", 1), (false, "ok perfect thanks", 0.5)])
    owed(46, true, "excited update, no cue", [(true, "game?", 1), (false, "we won!!!", 0.5)])
    owed(47, true, "engage-y question", [(true, "hey", 1), (false, "can you believe it's already friday", 0.5)])
    owed(48, false, "longer confirmation", [(true, "plan?", 1), (false, "see you tomorrow at the thing", 0.5)])
    owed(49, false, "anytime closer", [(true, "thanks!", 1), (false, "anytime!", 0.5)])
    owed(53, true, "plan confirmation question", [(true, "hey", 2), (false, "are we still on for tonight?", 1)])
    follow(50, true, "close, quiet 22d", count: 10, oneWay: false, span: 35, last: 22)
    follow(51, false, "one-way blast", count: 5, oneWay: true, span: 40, last: 50, saved: false)
    follow(52, false, "balanced but too soon (cadence)", count: 8, oneWay: false, span: 30, last: 5)

    return c
  }

  func test_deterministicEval() throws {
    let cases = Self.cases()
    var tp = 0, fp = 0, fn = 0, tn = 0
    var fpIDs: [Int] = [], fnIDs: [Int] = []
    for c in cases {
      let msgs = c.msgs.enumerated().map { (i, m) in
        DontGhostMessage(id: Int64(i + 1), fromMe: m.fromMe, senderName: m.fromMe ? "You" : "Them", body: m.body, sentAt: now.addingTimeInterval(-m.daysAgo * 86_400))
      }
      let s = DontGhostController.scoreCandidate(kind: c.kind, messages: msgs, isSavedContact: c.saved, now: now)
      switch (s.surfaced, c.truth) {
      case (true, true): tp += 1
      case (true, false): fp += 1; fpIDs.append(c.id)
      case (false, true): fn += 1; fnIDs.append(c.id)
      case (false, false): tn += 1
      }
    }
    let precision = (tp + fp) == 0 ? 0 : Double(tp) / Double(tp + fp)
    let recall = (tp + fn) == 0 ? 0 : Double(tp) / Double(tp + fn)
    let f1 = (precision + recall) == 0 ? 0 : 2 * precision * recall / (precision + recall)
    let acc = Double(tp + tn) / Double(cases.count)
    print(String(format: "EVAL_RESULT n=%d tp=%d fp=%d fn=%d tn=%d precision=%.3f recall=%.3f f1=%.3f acc=%.3f",
                 cases.count, tp, fp, fn, tn, precision, recall, f1, acc))
    print("EVAL_FP=\(fpIDs.sorted())  // surfaced but should NOT")
    print("EVAL_FN=\(fnIDs.sorted())  // missed but SHOULD surface")
    for c in cases where fpIDs.contains(c.id) || fnIDs.contains(c.id) {
      print("  miss #\(c.id) [\(c.kind)] truth=\(c.truth) — \(c.note)")
    }
    writeFixturesJSON(cases)
    // Regression floor: the scorer reached F1 0.98 / recall 1.0 against the LLM
    // baseline after tuning. Guard against precision regressions; recall must
    // stay perfect on this set (we never want to start dropping real surfaces).
    XCTAssertEqual(fn, 0, "deterministic scorer dropped a thread it should surface (recall regressed)")
    XCTAssertGreaterThanOrEqual(f1, 0.92, "deterministic F1 regressed below floor")
  }

  /// Emit the fixtures (no labels) + a separate truth map so the LLM-baseline
  /// pass can label the identical set with the production classify prompt.
  private func writeFixturesJSON(_ cases: [EvalCase]) {
    let iso = ISO8601DateFormatter()
    var fixtures: [[String: Any]] = []
    var truth: [String: Bool] = [:]
    for c in cases {
      let messages = c.msgs.enumerated().map { (i, m) -> [String: Any] in
        ["from": m.fromMe ? "me" : "them",
         "sent_at": iso.string(from: now.addingTimeInterval(-m.daysAgo * 86_400)),
         "body": m.body]
      }
      fixtures.append([
        "id": c.id,
        "kind": c.kind == .owedReply ? "owed_reply" : "follow_up",
        "person": "Person \(c.id)",
        "messages": messages,
      ])
      truth[String(c.id)] = c.truth
    }
    let dir = URL(fileURLWithPath: "/tmp/dg-eval")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let f = try? JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys]) {
      try? f.write(to: dir.appendingPathComponent("fixtures.json"))
    }
    if let t = try? JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys]) {
      try? t.write(to: dir.appendingPathComponent("truth.json"))
    }
  }
}
