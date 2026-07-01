import Foundation

/// Shared business / non-person detector for the menu-bar app — the Swift twin of
/// `mcps/wrapped-generator/src/business.ts`. Keep the two token lists in sync
/// (same dual-impl discipline as `canonHandle`) so a business one surface filters
/// is recognized everywhere: Don't Ghost (skip), Severance (auto-bin), and — via
/// the TS twin — Keep Tabs, Birthdays, and Wrapped.
///
/// Two layers, both metadata-safe (handle + saved name only — no message bodies):
///   • handle — shortcodes, toll-free, WhatsApp service ids, no-reply emails.
///   • name   — business-name tokens, matched on WORD BOUNDARIES so a surname
///              like "Banks" / "Healey" is never mistaken for "bank" / "health".
enum BusinessFilter {
  // MIRROR of business.ts BUSINESS_NAME_TOKENS — keep in sync.
  static let nameTokens: [String] = [
    // delivery / commerce
    "doordash", "door dash", "ubereats", "uber", "lyft", "amazon", "instacart",
    "grubhub", "postmates", "shipt", "ups", "fedex", "usps", "dhl",
    // finance
    "bank", "chase", "wells fargo", "bank of america", "amex", "american express",
    "paypal", "venmo", "capital one", "billing", "receipt", "invoice", "payment",
    "mortgage", "insurance", "geico", "state farm",
    // security / automated / notifications
    "alert", "alerts", "verification", "verify", "otp", "security code",
    "verification code", "your code", "do not reply", "no reply", "noreply",
    "donotreply", "notification", "notifications", "unsubscribe",
    // travel / reservations
    "airbnb", "vrbo", "delta", "united", "southwest", "jetblue",
    "american airlines", "marriott", "hilton", "reservation", "booking",
    // health (the One Medical class)
    "one medical", "medical", "clinic", "pharmacy", "cvs", "walgreens", "dentist",
    "dental", "doctor", "hospital", "urgent care", "healthcare", "kaiser",
    "labcorp", "quest diagnostics",
    // services / appointments
    "appointment", "salon", "spa", "support", "customer service", "tech support",
    "warranty",
    // telecom / utility
    "verizon", "t-mobile", "comcast", "xfinity", "spectrum",
  ]

  // MIRROR of business.ts NO_REPLY_EMAIL_TOKENS.
  private static let noReplyEmailTokens: [String] = [
    "no-reply", "noreply", "no_reply", "donotreply", "do-not-reply", "notifications",
    "notification", "alerts", "alert", "support", "billing", "receipt", "receipts",
    "info@", "hello@", "mailer", "no.reply", "account-update",
    "rbm.goog", // Google Rich Business Messaging — every @rbm.goog sender is a verified business
  ]

  private static let tollFreeNPAs: Set<String> = ["800", "833", "844", "855", "866", "877", "888"]

  private static let nameRegex: NSRegularExpression? = {
    let escaped = nameTokens.map { NSRegularExpression.escapedPattern(for: $0) }
    return try? NSRegularExpression(
      pattern: "\\b(" + escaped.joined(separator: "|") + ")\\b",
      options: [.caseInsensitive]
    )
  }()

  /// A saved Contacts name that names a business rather than a person.
  static func looksLikeBusinessName(_ name: String) -> Bool {
    guard let regex = nameRegex else { return false }
    let range = NSRange(name.startIndex..., in: name)
    return regex.firstMatch(in: name, options: [], range: range) != nil
  }

  /// A handle (phone / email / WhatsApp id) that belongs to a business: a
  /// shortcode, toll-free number, WhatsApp service id, or a no-reply email.
  static func looksLikeBusinessHandle(_ handle: String) -> Bool {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasSuffix("@s.whatsapp.net"), let at = trimmed.firstIndex(of: "@") {
      let digits = trimmed[..<at].filter(\.isNumber)
      return digits.count >= 3 && digits.count <= 6
    }
    if trimmed.contains("@") {
      return noReplyEmailTokens.contains { trimmed.contains($0) }
    }
    let digits = trimmed.filter(\.isNumber)
    if digits.count >= 3 && digits.count <= 6 { return true }
    if digits.count == 11 && digits.hasPrefix("1") {
      let npa = String(digits.dropFirst().prefix(3))
      return tollFreeNPAs.contains(npa)
    }
    return false
  }

  /// True when the counterparty is a business by EITHER its handle or its name.
  static func looksLikeBusiness(handle: String, name: String) -> Bool {
    looksLikeBusinessHandle(handle) || looksLikeBusinessName(name)
  }
}
