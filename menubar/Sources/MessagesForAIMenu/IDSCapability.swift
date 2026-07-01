import Foundation
import ObjectiveC.runtime

/// Apple Identity Service (IDS) capability lookup — the same signal that drives
/// Messages.app's blue/green: is this destination registered for iMessage?
///
/// Backed by the private `IDS.framework` (`IDSIDQueryController`). Acceptable
/// here because Ghostie ships Developer-ID (not the Mac App Store). EVERYTHING
/// is guarded: if the framework, class, or selector is ever absent (a future
/// macOS that moved or renamed it), every lookup degrades to `.unknown` and
/// callers fall back to their existing behavior. This is a READ-ONLY directory
/// query — no message is ever sent, and Messages.app is never launched or
/// automated.
enum IDSVerdict: Equatable {
  /// Registered for iMessage (IDS status 1) — send blue.
  case iMessage
  /// Not on iMessage (IDS status 2) — route SMS/RCS instead of leading with iMessage.
  case notIMessage
  /// Couldn't determine (status 0/try-again, timeout, no IDS account, or the
  /// private API is unavailable). Callers must treat this as "no opinion" and
  /// keep their current behavior.
  case unknown
}

struct IDSCapability {
  /// IDS service identifier for iMessage. (FaceTime/other services use different ids.)
  static let iMessageService = "com.apple.madrid"
  private static let frameworkPath = "/System/Library/PrivateFrameworks/IDS.framework/IDS"
  private static let listenerID = "com.sunriselabs.ghostie.ids-probe"

  // MARK: - Pure helpers (unit-tested, no framework dependency)

  /// Map an IDS status integer to a verdict. 1 = Available, 2 = Unavailable;
  /// everything else (0 = Unknown, 3 = try-again, …) stays `.unknown` so callers
  /// remain conservative.
  static func verdict(fromStatus status: Int) -> IDSVerdict {
    switch status {
    case 1: return .iMessage
    case 2: return .notIMessage
    default: return .unknown
    }
  }

  /// Format a handle as an IDS destination URI. Emails → `mailto:`, everything
  /// else → `tel:`. Already-prefixed inputs pass through untouched.
  static func destinationURI(for handle: String) -> String {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") { return trimmed }
    return trimmed.contains("@") ? "mailto:\(trimmed)" : "tel:\(trimmed)"
  }

  /// Reduce a raw IDS result (destination URI → status int) to verdicts keyed by
  /// the ORIGINAL handles the caller asked about. Handles absent from the result
  /// map to `.unknown`.
  static func verdicts(from resultByURI: [String: Int], handles: [String]) -> [String: IDSVerdict] {
    var out: [String: IDSVerdict] = [:]
    for handle in handles {
      let uri = destinationURI(for: handle)
      out[handle] = resultByURI[uri].map(verdict(fromStatus:)) ?? .unknown
    }
    return out
  }

  // MARK: - Live lookup (guarded dynamic call; sends nothing)

  /// How long to wait for the IDS callback before giving up (→ `.unknown`).
  var timeout: TimeInterval = 8
  /// Test seam: when set, the live framework call is bypassed and this supplies
  /// the raw status dict (nil → simulate total failure). Production leaves it nil.
  var rawLookupOverride: (([String]) -> [String: Int]?)?

  /// Best-effort capability lookup. Returns `.unknown` for every handle on ANY
  /// failure (framework absent, selector gone, timeout, or no IDS account).
  func status(for handles: [String]) async -> [String: IDSVerdict] {
    guard !handles.isEmpty else { return [:] }
    let raw: [String: Int]?
    if let rawLookupOverride {
      raw = rawLookupOverride(handles)
    } else {
      raw = await Self.rawIDSLookup(uris: handles.map(Self.destinationURI(for:)), timeout: timeout)
    }
    guard let raw else {
      return Dictionary(uniqueKeysWithValues: handles.map { ($0, IDSVerdict.unknown) })
    }
    return Self.verdicts(from: raw, handles: handles)
  }

  /// The dynamic, guarded IDS call. Returns nil (→ all `.unknown`) on any problem.
  private static func rawIDSLookup(uris: [String], timeout: TimeInterval) async -> [String: Int]? {
    guard dlopen(frameworkPath, RTLD_NOW) != nil,
          let cls: AnyClass = NSClassFromString("IDSIDQueryController") else {
      return nil
    }
    let sharedSel = NSSelectorFromString("sharedInstance")
    guard let meta = object_getClass(cls), class_respondsToSelector(meta, sharedSel),
          let controller = (cls as AnyObject).perform(sharedSel)?.takeUnretainedValue() as? NSObject else {
      return nil
    }
    let sel = NSSelectorFromString("refreshIDStatusForDestinations:service:listenerID:queue:completionBlock:")
    guard controller.responds(to: sel) else { return nil }
    let imp = controller.method(for: sel)

    return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Int]?, Never>) in
      let guardOnce = ResumeOnce(continuation)

      let completion: @convention(block) (NSDictionary?) -> Void = { dict in
        var out: [String: Int] = [:]
        dict?.forEach { key, value in
          guard let number = value as? NSNumber else { return }
          out[(key as? String) ?? "\(key)"] = number.intValue
        }
        guardOnce.resume(out)
      }

      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { guardOnce.resume(nil) }

      typealias IDSFn = @convention(c) (
        NSObject, Selector, NSArray, NSString, NSString, DispatchQueue,
        @convention(block) (NSDictionary?) -> Void
      ) -> Void
      let fn = unsafeBitCast(imp, to: IDSFn.self)
      fn(
        controller, sel,
        uris as NSArray,
        iMessageService as NSString,
        listenerID as NSString,
        DispatchQueue.global(),
        completion
      )
    }
  }
}

/// Resumes a continuation exactly once — the IDS callback and the timeout race,
/// and resuming a CheckedContinuation twice traps.
private final class ResumeOnce {
  private var continuation: CheckedContinuation<[String: Int]?, Never>?
  private let lock = NSLock()
  init(_ continuation: CheckedContinuation<[String: Int]?, Never>) { self.continuation = continuation }
  func resume(_ value: [String: Int]?) {
    lock.lock(); defer { lock.unlock() }
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(returning: value)
  }
}
