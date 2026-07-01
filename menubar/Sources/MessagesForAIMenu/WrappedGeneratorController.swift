import Foundation

// File-scope (not actor-isolated) so the nonisolated process helpers can use
// it. Stable name → re-runs overwrite rather than pile up.
private let kWrappedFile = "texting-wrapped.html"

/// Spawns the bundled `wrapped-generator` Mach-O (a sibling inner binary,
/// signed with the same identifier, so it inherits Full Disk Access via
/// launcher attribution just like the daemons). The generator reads chat.db
/// read-only, runs the deterministic pipeline, and writes ONE self-contained
/// Wrapped HTML to `--out` — the engine always computes BOTH the past-year and
/// all-time metric sets and the page carries the in-page window toggle, so
/// there is exactly one job per generation. No daemon / socket — one-shot.
@MainActor
final class WrappedGeneratorController: ObservableObject {
  enum State: Equatable {
    case idle
    case generating
    case done(WrappedGeneratedExperience)
    case failed(reason: String, fdaMissing: Bool)
  }

  @Published private(set) var state: State = .idle

  private let binaryResolver: () -> URL?
  private let jobRunner: @Sendable (URL, URL, Bool) throws -> URL

  init(
    binaryResolver: @escaping () -> URL? = WrappedGeneratorController.defaultBinaryURL,
    jobRunner: @escaping @Sendable (URL, URL, Bool) throws -> URL = { binURL, outDir, includeNames in
      try WrappedGeneratorController.runJob(
        binURL: binURL,
        outDir: outDir,
        includeNames: includeNames
      )
    }
  ) {
    self.binaryResolver = binaryResolver
    self.jobRunner = jobRunner
  }

  /// The stable output location — also how a past run is found again, so the
  /// pane can land on the story instead of an empty frame.
  nonisolated static func defaultOutputDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Downloads")
      .appendingPathComponent("texting-wrapped")
  }

  /// A Wrapped left behind by a previous run (stable filename), or nil.
  /// `includeNames` can't be recovered from the HTML; the caller passes its
  /// last persisted choice.
  nonisolated static func existingExperience(
    includeNames: Bool,
    outputDirectory: URL = defaultOutputDirectory()
  ) -> WrappedGeneratedExperience? {
    let out = outputDirectory.appendingPathComponent(kWrappedFile)
    guard FileManager.default.fileExists(atPath: out.path) else { return nil }
    return WrappedGeneratedExperience(
      url: out,
      readAccessDirectory: outputDirectory,
      includeNames: includeNames
    )
  }

  /// Idle-only restore: never clobbers a run in flight or a fresh result.
  func restoreExistingIfIdle(includeNames: Bool) {
    guard case .idle = state else { return }
    if let experience = Self.existingExperience(includeNames: includeNames) {
      state = .done(experience)
    }
  }

  func generate(includeNames: Bool) {
    if case .generating = state { return } // already running
    guard let binURL = binaryResolver() else {
      state = .failed(reason: "The Wrapped engine isn't bundled in this build yet.", fdaMissing: false)
      return
    }
    let outDir = Self.defaultOutputDirectory()

    state = .generating
    let startedAt = Date()
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.wrapped.rawValue)
    ])
    let jobRunner = self.jobRunner
    Task.detached(priority: .userInitiated) {
      do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let opened = try jobRunner(binURL, outDir, includeNames)
        let experience = WrappedGeneratedExperience(
          url: opened,
          readAccessDirectory: outDir,
          includeNames: includeNames
        )
        await MainActor.run {
          self.state = .done(experience)
          AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
            .lab: .string(AnalyticsLab.wrapped.rawValue),
            .resultCountBucket: .string(AnalyticsClient.resultCountBucket(1)),
            .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
          ])
        }
      } catch let e as GenError {
        await MainActor.run {
          self.state = .failed(reason: e.message, fdaMissing: e.fdaMissing)
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.wrapped.rawValue),
            .errorCategory: .string(e.fdaMissing ? AnalyticsErrorCategory.fullDiskAccess.rawValue : AnalyticsErrorCategory.unknown.rawValue)
          ])
        }
      } catch {
        await MainActor.run {
          self.state = .failed(reason: error.localizedDescription, fdaMissing: false)
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.wrapped.rawValue),
            .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
          ])
        }
      }
    }
  }

  func reset() { state = .idle }

  // MARK: - process orchestration

  private struct GenError: Error { let message: String; let fdaMissing: Bool }

  /// Runs the generator once; returns the file to open. The engine computes
  /// both metric windows internally — no window flags.
  nonisolated private static func runJob(
    binURL: URL, outDir: URL, includeNames: Bool
  ) throws -> URL {
    let out = outDir.appendingPathComponent(kWrappedFile)
    var args = ["--out", out.path]
    if !includeNames { args.append("--no-people") }
    try run(binURL, args)
    return out
  }

  nonisolated private static func run(_ binURL: URL, _ args: [String]) throws {
    let proc = Process()
    proc.executableURL = binURL
    proc.arguments = args
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = FileHandle.nullDevice // HTML goes to --out, not stdout
    do {
      try proc.run()
    } catch {
      throw GenError(message: "Couldn't start the Wrapped engine: \(error.localizedDescription)", fdaMissing: false)
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      let stderr = String(data: errData, encoding: .utf8) ?? ""
      // Exit 3 / chatdb_open_failed → Full Disk Access not granted to the engine.
      let fda = proc.terminationStatus == 3 || stderr.contains("chatdb_open_failed")
      // Note: there's deliberately no "low message history" branch. The engine
      // treats an empty body set as non-fatal — it omits the emoji/age cards and
      // still produces a valid Wrapped (exit 0), so that case never reaches here.
      // If a minimum-history gate is added later, have the engine emit a distinct
      // exit code and key off that, not a stderr substring.
      let msg: String
      if fda {
        msg = "The Wrapped engine couldn't read your Messages database. Grant Full Disk Access in Settings, then try again."
      } else {
        msg = "The Wrapped engine exited with an error (code \(proc.terminationStatus))."
      }
      throw GenError(message: msg, fdaMissing: fda)
    }
  }

  // MARK: - binary resolution (mirrors IMessageDaemonController)

  nonisolated private static func defaultBinaryURL() -> URL? {
    let binaryName = "wrapped-generator"
    let bundle = Bundle.main.bundleURL
    let inBundle = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
    let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    return nil
  }
}
