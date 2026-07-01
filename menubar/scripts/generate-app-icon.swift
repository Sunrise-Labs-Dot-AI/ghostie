#!/usr/bin/env swift

import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let scriptsDir = scriptURL.deletingLastPathComponent()
let menubarDir = scriptsDir.deletingLastPathComponent()
let repoRoot = menubarDir.deletingLastPathComponent()
let assetsDir = menubarDir.appendingPathComponent("Assets", isDirectory: true)
let iconsetDir = assetsDir.appendingPathComponent("MessagesForAI.iconset", isDirectory: true)
let icnsURL = assetsDir.appendingPathComponent("MessagesForAI.icns")
let sourceURL = repoRoot
  .appendingPathComponent("brand/ghostie/sprites/out", isDirectory: true)
  .appendingPathComponent("app-icon-1024.png")

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
  fputs("Missing Ghostie icon source at \(sourceURL.path)\n", stderr)
  exit(1)
}

try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderPNG(size: Int) throws -> Data {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else {
    throw NSError(domain: "GhostieIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create \(size)x\(size) bitmap"])
  }

  rep.size = NSSize(width: size, height: size)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: size, height: size).fill()
  sourceImage.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
  )
  NSGraphicsContext.restoreGraphicsState()

  guard let data = rep.representation(using: .png, properties: [:]) else {
    throw NSError(domain: "GhostieIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(size)x\(size) PNG"])
  }
  return data
}

let entries: [(pixels: Int, name: String)] = [
  (16, "icon_16x16.png"),
  (32, "icon_16x16@2x.png"),
  (32, "icon_32x32.png"),
  (64, "icon_32x32@2x.png"),
  (128, "icon_128x128.png"),
  (256, "icon_128x128@2x.png"),
  (256, "icon_256x256.png"),
  (512, "icon_256x256@2x.png"),
  (512, "icon_512x512.png"),
  (1024, "icon_512x512@2x.png")
]

for entry in entries {
  let outputURL = iconsetDir.appendingPathComponent(entry.name)
  try renderPNG(size: entry.pixels).write(to: outputURL, options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
  fputs("iconutil failed with status \(iconutil.terminationStatus)\n", stderr)
  exit(iconutil.terminationStatus)
}

print("Generated \(icnsURL.path) from \(sourceURL.path)")
