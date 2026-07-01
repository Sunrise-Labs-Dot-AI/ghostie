import Foundation

// Deep Read — the premium Wrapped section that reasons over AGGREGATE texting
// stats with the user's own model (PremiumGate: subscription OR BYOK).
//
// Privacy bar (same as Style): message bodies are probed locally and
// reduced to booleans/counts at the read site; the model receives aggregates
// plus a budgeted metadata sample. No bodies, no names, no handles — contacts
// are positional pseudonyms ("c1", "c2", …).
//
// Everything in this file is pure (no I/O, no actors) so prompt assembly,
// response parsing, and the aggregation math carry plain unit tests.
// Disk/SQLite/network live in DeepReadController.swift.

enum DeepReadError: Error, Equatable {
  case chatDbMissing
  case sqliteOpen(String)
  case sqlitePrepare(String)
  case noAPIKey
  case notEnoughHistory
  case invalidResponse
}

// MARK: - Metadata input

/// One message reduced to the metadata Deep Read may reason over. Built at
/// the chat.db read site via `DeepReadStyleProbe`; the body string never
/// outlives that call frame.
struct DeepReadRawMessage: Equatable {
  let chatID: Int
  let sentAt: Date
  let fromMe: Bool
  let bodyChars: Int
  let lowercaseStart: Bool
  let endsPeriod: Bool
  let endsExclaim: Bool
  let endsQuestion: Bool
  let hasEmoji: Bool
}

/// The only place message text is touched — output is booleans + a length.
enum DeepReadStyleProbe {
  static func probe(chatID: Int, sentAt: Date, fromMe: Bool, body: String) -> DeepReadRawMessage {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLetter = trimmed.first(where: \.isLetter)
    let last = trimmed.last
    return DeepReadRawMessage(
      chatID: chatID,
      sentAt: sentAt,
      fromMe: fromMe,
      bodyChars: trimmed.count,
      lowercaseStart: firstLetter?.isLowercase ?? false,
      endsPeriod: last == ".",
      endsExclaim: last == "!",
      endsQuestion: last == "?",
      hasEmoji: containsEmoji(trimmed)
    )
  }

  static func containsEmoji(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      scalar.properties.isEmojiPresentation
        || (scalar.properties.isEmoji && scalar.value >= 0x1F000)
    }
  }
}

// MARK: - Aggregate stats (the full model payload — nothing else is sent)

struct DeepReadStats: Codable, Equatable {
  struct Style: Codable, Equatable {
    var messageCount = 0
    var medianChars = 0
    var pctLowercaseStart = 0
    var pctEndingPeriod = 0
    var pctEndingExclaim = 0
    var pctEndingQuestion = 0
    var pctWithEmoji = 0
  }

  struct Ghosting: Codable, Equatable {
    var threadsSampled = 0
    /// 1:1 threads whose last word is theirs, older than the hanging threshold.
    var threadsAwaitingMyReply = 0
    var threadsAwaitingTheirReply = 0
    var medianReplyMinutes: Int?
    var p90ReplyMinutes: Int?
    var pctRepliesOver24h = 0
  }

  struct SampleRecord: Codable, Equatable {
    /// Positional pseudonym ("c1", "c2", …) — never a name or handle.
    var contact: String
    var fromMe: Bool
    /// Calendar weekday component (1 = Sunday … 7 = Saturday).
    var weekday: Int
    var hour: Int
    var chars: Int
    var hasEmoji: Bool
    var replyMinutes: Int?
  }

  var windowDays: Int
  var totalMessages: Int
  var outboundOverall: Style
  /// Weekday 9:00–18:00 vs everything else — the severance evidence.
  var outboundWorkHours: Style
  var outboundOffHours: Style
  var ghosting: Ghosting
  var sample: [SampleRecord]
}

// MARK: - Aggregation

enum DeepReadAggregator {
  /// Budget for the per-message metadata sample sent alongside aggregates.
  static let sampleBudget = 120
  /// A direction flip older than this is a new conversation, not a reply.
  static let replyCapMinutes = 7 * 24 * 60
  /// Last word theirs and older than this = a thread left hanging.
  static let hangingThresholdDays = 3
  static let workHours = 9..<18

  static func aggregate(
    _ messages: [DeepReadRawMessage],
    now: Date = Date(),
    calendar: Calendar = .current,
    windowDays: Int = 365
  ) -> DeepReadStats {
    let sorted = messages.sorted { $0.sentAt < $1.sentAt }

    var chatOrder: [Int] = []
    var byChat: [Int: [DeepReadRawMessage]] = [:]
    for message in sorted {
      if byChat[message.chatID] == nil { chatOrder.append(message.chatID) }
      byChat[message.chatID, default: []].append(message)
    }
    let contactNames = Dictionary(
      uniqueKeysWithValues: chatOrder.enumerated().map { ($0.element, "c\($0.offset + 1)") }
    )

    // Per-chat walk: reply latencies (inbound → outbound flips) + hanging threads.
    var ghosting = DeepReadStats.Ghosting(threadsSampled: byChat.count)
    var latencies: [Int] = []
    var annotated: [(message: DeepReadRawMessage, replyMinutes: Int?)] = []
    for chatID in chatOrder {
      let thread = byChat[chatID] ?? []
      for (index, message) in thread.enumerated() {
        var replyMinutes: Int?
        if index > 0, message.fromMe, !thread[index - 1].fromMe {
          let minutes = Int((message.sentAt.timeIntervalSince(thread[index - 1].sentAt) / 60).rounded())
          if minutes >= 0, minutes <= replyCapMinutes {
            replyMinutes = minutes
            latencies.append(minutes)
          }
        }
        annotated.append((message, replyMinutes))
      }
      if let last = thread.last {
        let ageDays = now.timeIntervalSince(last.sentAt) / 86_400
        if ageDays > Double(hangingThresholdDays) {
          if last.fromMe {
            ghosting.threadsAwaitingTheirReply += 1
          } else {
            ghosting.threadsAwaitingMyReply += 1
          }
        }
      }
    }
    let sortedLatencies = latencies.sorted()
    ghosting.medianReplyMinutes = percentile(sortedLatencies, 0.5)
    ghosting.p90ReplyMinutes = percentile(sortedLatencies, 0.9)
    ghosting.pctRepliesOver24h = percent(
      latencies.filter { $0 > 24 * 60 }.count,
      of: latencies.count
    )

    let outbound = sorted.filter { $0.fromMe && $0.bodyChars > 0 }
    let work = outbound.filter { isWorkHours($0.sentAt, calendar: calendar) }
    let off = outbound.filter { !isWorkHours($0.sentAt, calendar: calendar) }

    return DeepReadStats(
      windowDays: windowDays,
      totalMessages: sorted.count,
      outboundOverall: style(of: outbound),
      outboundWorkHours: style(of: work),
      outboundOffHours: style(of: off),
      ghosting: ghosting,
      sample: sample(annotated.sorted { $0.message.sentAt < $1.message.sentAt },
                     contactNames: contactNames,
                     calendar: calendar)
    )
  }

  static func isWorkHours(_ date: Date, calendar: Calendar) -> Bool {
    let weekday = calendar.component(.weekday, from: date)
    let hour = calendar.component(.hour, from: date)
    return weekday >= 2 && weekday <= 6 && workHours.contains(hour)
  }

  private static func style(of messages: [DeepReadRawMessage]) -> DeepReadStats.Style {
    guard !messages.isEmpty else { return DeepReadStats.Style() }
    let lengths = messages.map(\.bodyChars).sorted()
    return DeepReadStats.Style(
      messageCount: messages.count,
      medianChars: percentile(lengths, 0.5) ?? 0,
      pctLowercaseStart: percent(messages.filter(\.lowercaseStart).count, of: messages.count),
      pctEndingPeriod: percent(messages.filter(\.endsPeriod).count, of: messages.count),
      pctEndingExclaim: percent(messages.filter(\.endsExclaim).count, of: messages.count),
      pctEndingQuestion: percent(messages.filter(\.endsQuestion).count, of: messages.count),
      pctWithEmoji: percent(messages.filter(\.hasEmoji).count, of: messages.count)
    )
  }

  private static func sample(
    _ annotated: [(message: DeepReadRawMessage, replyMinutes: Int?)],
    contactNames: [Int: String],
    calendar: Calendar
  ) -> [DeepReadStats.SampleRecord] {
    let picked: [(message: DeepReadRawMessage, replyMinutes: Int?)]
    if annotated.count <= sampleBudget {
      picked = annotated
    } else if sampleBudget == 1 {
      picked = [annotated[annotated.count / 2]]
    } else {
      let step = Double(annotated.count - 1) / Double(sampleBudget - 1)
      picked = (0..<sampleBudget).map { annotated[Int((Double($0) * step).rounded())] }
    }
    return picked.map { entry in
      DeepReadStats.SampleRecord(
        contact: contactNames[entry.message.chatID] ?? "c?",
        fromMe: entry.message.fromMe,
        weekday: calendar.component(.weekday, from: entry.message.sentAt),
        hour: calendar.component(.hour, from: entry.message.sentAt),
        chars: entry.message.bodyChars,
        hasEmoji: entry.message.hasEmoji,
        replyMinutes: entry.replyMinutes
      )
    }
  }

  private static func percentile(_ sorted: [Int], _ p: Double) -> Int? {
    guard !sorted.isEmpty else { return nil }
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index]
  }

  private static func percent(_ part: Int, of whole: Int) -> Int {
    guard whole > 0 else { return 0 }
    return Int((Double(part) / Double(whole) * 100).rounded())
  }
}

// MARK: - Insights (the model's structured answer; cached to disk)

struct DeepReadInsights: Codable, Equatable {
  struct Voice: Codable, Equatable {
    var traits: [String]
    var summary: String
  }

  struct Ghosting: Codable, Equatable {
    var headline: String
    var roast: String
  }

  struct Vibe: Codable, Equatable {
    var archetype: String
    var evidence: String
  }

  struct Severance: Codable, Equatable {
    /// 0 = the same person all day, 100 = fully severed.
    var score: Int
    var oneLiner: String

    static func clamped(_ score: Int) -> Int {
      min(100, max(0, score))
    }
  }

  var voice: Voice
  var ghosting: Ghosting
  var vibe: Vibe
  var severance: Severance
  var generatedAt: Date
  var modelID: String
}

// MARK: - Prompt

enum DeepReadPrompt {
  static func make(stats: DeepReadStats) -> String {
    """
    You turn privacy-scrubbed aggregate texting statistics into a short, sharp personality read for a "Texting Wrapped" story.

    Privacy constraints:
    - You are receiving aggregate counts, percentages, and a sampled list of per-message metadata records only.
    - You are not receiving message bodies, names, phone numbers, emails, or handles. Contacts are positional pseudonyms like "c1".
    - Do not invent specific people, events, quotes, or relationships. Every claim must trace to the numbers.
    - Do not ask for message bodies.

    Voice: confident, playful, lightly roasty — never mean, never clinical. Each field renders on a story card, so keep every string tight.

    Field guide:
    - voice_signature: the signature of how this person texts (length, casing, punctuation, emoji, pacing).
    - ghosting: how often they leave people hanging, grounded in the reply latencies and hanging-thread counts. The roast stays gentle.
    - vibe: a 2-4 word archetype naming their overall texting energy, with one sentence of evidence citing the stats.
    - severance: how differently they text during weekday work hours (outbound_work_hours) versus off hours (outbound_off_hours). 0 = the same person all day, 100 = fully severed.

    Return strict JSON only, exactly this shape:
    {
      "voice_signature": { "traits": ["3-5 short trait phrases"], "summary": "one sentence" },
      "ghosting": { "headline": "one short line", "roast": "one gentle roast sentence" },
      "vibe": { "archetype": "2-4 word archetype", "evidence": "one sentence citing the stats" },
      "severance": { "score": 0, "one_liner": "one sentence" }
    }

    Stats:
    \(statsJSON(stats))
    """
  }

  static func statsJSON(_ stats: DeepReadStats) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard let data = try? encoder.encode(stats),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
  }
}

// MARK: - Tolerant response parse

enum DeepReadParser {
  /// Accepts fenced or prose-wrapped JSON, traits as a string or array,
  /// score as a number or numeric string (clamped to 0…100). Missing
  /// sections are a hard failure — the card has four fixed slots.
  static func parse(_ raw: String, modelID: String, generatedAt: Date = Date()) throws -> DeepReadInsights {
    guard let object = jsonObject(in: raw),
          let voice = voice(object["voice_signature"] ?? object["voice"]),
          let ghosting = ghosting(object["ghosting"]),
          let vibe = vibe(object["vibe"]),
          let severance = severance(object["severance"]) else {
      throw DeepReadError.invalidResponse
    }
    return DeepReadInsights(
      voice: voice,
      ghosting: ghosting,
      vibe: vibe,
      severance: severance,
      generatedAt: generatedAt,
      modelID: modelID
    )
  }

  private static func jsonObject(in raw: String) -> [String: Any]? {
    guard let start = raw.firstIndex(of: "{"),
          let end = raw.lastIndex(of: "}"),
          start < end else { return nil }
    guard let data = String(raw[start...end]).data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func voice(_ value: Any?) -> DeepReadInsights.Voice? {
    guard let dict = value as? [String: Any] else { return nil }
    var traits: [String] = []
    if let array = dict["traits"] as? [Any] {
      traits = array.compactMap { cleanString($0) }
    } else if let single = cleanString(dict["traits"]) {
      traits = [single]
    }
    let summary = cleanString(dict["summary"]) ?? ""
    guard !traits.isEmpty || !summary.isEmpty else { return nil }
    return DeepReadInsights.Voice(traits: traits, summary: summary)
  }

  private static func ghosting(_ value: Any?) -> DeepReadInsights.Ghosting? {
    guard let dict = value as? [String: Any],
          let headline = cleanString(dict["headline"]) else { return nil }
    return DeepReadInsights.Ghosting(headline: headline, roast: cleanString(dict["roast"]) ?? "")
  }

  private static func vibe(_ value: Any?) -> DeepReadInsights.Vibe? {
    guard let dict = value as? [String: Any],
          let archetype = cleanString(dict["archetype"]) else { return nil }
    return DeepReadInsights.Vibe(archetype: archetype, evidence: cleanString(dict["evidence"]) ?? "")
  }

  private static func severance(_ value: Any?) -> DeepReadInsights.Severance? {
    guard let dict = value as? [String: Any],
          let score = number(dict["score"]) else { return nil }
    let line = cleanString(dict["one_liner"]) ?? cleanString(dict["oneLiner"]) ?? ""
    // Clamp BEFORE the Int conversion: the string path can hand back any
    // finite Double ("1e300"), and Int(Double) traps outside Int's range.
    return DeepReadInsights.Severance(
      score: Int(min(100, max(0, score.rounded()))),
      oneLiner: line
    )
  }

  private static func cleanString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func number(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    let parsed: Double?
    if let number = value as? NSNumber {
      parsed = number.doubleValue
    } else if let string = value as? String {
      parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
      parsed = nil
    }
    // Swift's Double(String) accepts "nan"/"inf"; rounding NaN and converting
    // to Int is a fatal trap, so hostile non-finite scores are a parse
    // failure, never a crash.
    guard let parsed, parsed.isFinite else { return nil }
    return parsed
  }
}
