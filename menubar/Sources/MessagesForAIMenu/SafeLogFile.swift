import Foundation
import Darwin

/// Opens log files for append WITHOUT following symlinks (issue #83).
///
/// The menu-bar app holds Full Disk Access. If a same-user process replaces a log
/// path (`~/.messages-mcp/logs/*.log`, `menubar-events.jsonl`) with a symlink to a
/// TCC-protected file, an unguarded `open`/`FileHandle(forWritingTo:)` would follow
/// it and let the FDA app corrupt the target = confused-deputy write.
///
/// Defense: open with `O_NOFOLLOW` so a symlink AT the final path component fails
/// outright, and `lstat` the path + its parent directory, rejecting the open if
/// either is a symlink or not owned by this user. The file is created if absent
/// with 0600.
enum SafeLogFile {
  /// Open `url` for appending, refusing to follow a symlink. Returns nil if the
  /// path (or its parent) is a symlink / wrong-owner, or the open otherwise fails.
  static func openForAppending(at url: URL) -> FileHandle? {
    let path = url.path
    let uid = getuid()

    // Parent must exist, be a real directory we own, and not be a symlink.
    let parent = url.deletingLastPathComponent().path
    var pst = stat()
    guard lstat(parent, &pst) == 0,
          (pst.st_mode & S_IFMT) == S_IFDIR,
          pst.st_uid == uid
    else { return nil }

    // If the final path already exists, it must be a regular file we own and NOT
    // a symlink. lstat (not stat) so we inspect the link itself.
    var fst = stat()
    if lstat(path, &fst) == 0 {
      guard (fst.st_mode & S_IFMT) == S_IFREG, fst.st_uid == uid else { return nil }
    }

    // O_NOFOLLOW: if the final component is a symlink, open() fails with ELOOP
    // rather than following it. O_APPEND for the rotating-log append semantics.
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  /// Append `data` to `url` without following symlinks. Best-effort: returns false
  /// on any failure (the path was a symlink, wrong owner, unwritable, etc.).
  @discardableResult
  static func append(_ data: Data, to url: URL) -> Bool {
    guard let handle = openForAppending(at: url) else { return false }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      return true
    } catch {
      return false
    }
  }
}
