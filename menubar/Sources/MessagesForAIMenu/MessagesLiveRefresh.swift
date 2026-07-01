import Foundation

/// Event-driven refresh for the Messages tab: watches the SQLite WAL files
/// that receive every new-message write (chat.db-wal for iMessage, the
/// daemon's messages.db-wal for WhatsApp) and fires a debounced callback.
/// No polling — the pane stays live while open without burning CPU, and the
/// callback's fingerprint check filters out writes that don't change
/// anything user-visible.
@MainActor
final class MessagesLiveRefresh: ObservableObject {
  var onChange: (() -> Void)?

  private var sources: [DispatchSourceFileSystemObject] = []
  private var pending: Task<Void, Never>?
  private var desiredPaths: [String] = []

  func start(includeWhatsApp: Bool) {
    var paths = [
      AppStoragePaths.homeDirectory
        .appendingPathComponent("Library")
        .appendingPathComponent("Messages")
        .appendingPathComponent("chat.db-wal")
        .path
    ]
    if includeWhatsApp {
      paths.append(
        AppStoragePaths.homeDirectory
          .appendingPathComponent(".whatsapp-mcp")
          .appendingPathComponent("messages.db-wal")
          .path
      )
    }
    desiredPaths = paths
    rearm()
  }

  func stop() {
    desiredPaths = []
    pending?.cancel()
    pending = nil
    cancelSources()
  }

  /// (Re)open the watched files. Called on start and again after every fire:
  /// SQLite checkpoints can replace the WAL file, which would silently
  /// orphan a long-lived file descriptor.
  private func rearm() {
    cancelSources()
    for path in desiredPaths {
      let fd = open(path, O_EVTONLY)
      guard fd >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend, .delete, .rename],
        queue: .main
      )
      source.setEventHandler { [weak self] in
        self?.scheduleFire()
      }
      source.setCancelHandler {
        close(fd)
      }
      source.resume()
      sources.append(source)
    }
  }

  private func cancelSources() {
    for source in sources { source.cancel() }
    sources = []
  }

  private func scheduleFire() {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      self.onChange?()
      self.rearm()
    }
  }

  deinit {
    for source in sources { source.cancel() }
  }
}
