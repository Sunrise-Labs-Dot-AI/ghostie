import AppKit
import Foundation
import XCTest
@testable import MessagesForAIMenu

final class ComposerDropPolicyTests: XCTestCase {
  // MARK: firstAttachable

  func test_firstAttachableFileWinsOverLaterPayloads() {
    let first = URL(fileURLWithPath: "/tmp/a.png")
    let second = URL(fileURLWithPath: "/tmp/b.png")
    let pick = ComposerDropPolicy.firstAttachable(in: [
      .fileURL(first), .fileURL(second), .imageData(Data([0x01])),
    ])
    XCTAssertEqual(pick, .fileURL(first))
  }

  func test_firstAttachableSkipsWebURLsAndFolders() {
    let web = URL(string: "https://example.com/image.png")!
    let folder = URL(fileURLWithPath: "/tmp/somewhere", isDirectory: true)
    let file = URL(fileURLWithPath: "/tmp/photo.heic")
    let pick = ComposerDropPolicy.firstAttachable(in: [
      .fileURL(web), .fileURL(folder), .fileURL(file),
    ])
    XCTAssertEqual(pick, .fileURL(file))
  }

  func test_firstAttachableFallsBackToNonEmptyImageData() {
    let pick = ComposerDropPolicy.firstAttachable(in: [
      .imageData(Data()), .imageData(Data([0x01, 0x02])),
    ])
    XCTAssertEqual(pick, .imageData(Data([0x01, 0x02])))
  }

  func test_firstAttachableNilWhenNothingAttachable() {
    XCTAssertNil(ComposerDropPolicy.firstAttachable(in: []))
    XCTAssertNil(ComposerDropPolicy.firstAttachable(in: [
      .imageData(Data()),
      .fileURL(URL(string: "https://example.com")!),
      .fileURL(URL(fileURLWithPath: "/tmp/dir", isDirectory: true)),
    ]))
  }

  // MARK: imageTypeIdentifier

  func test_imageTypeIdentifierPrefersPNGOverOtherImageFlavors() {
    let picked = ComposerDropPolicy.imageTypeIdentifier(fromRegistered: [
      "public.url", "public.tiff", "public.png",
    ])
    XCTAssertEqual(picked, "public.png")
  }

  func test_imageTypeIdentifierFallsBackToFirstImageFlavor() {
    let picked = ComposerDropPolicy.imageTypeIdentifier(fromRegistered: [
      "public.html", "public.jpeg", "public.tiff",
    ])
    XCTAssertEqual(picked, "public.jpeg")
  }

  func test_imageTypeIdentifierNilWhenNothingConformsToImage() {
    XCTAssertNil(ComposerDropPolicy.imageTypeIdentifier(fromRegistered: [
      "public.url", "public.utf8-plain-text",
    ]))
    XCTAssertNil(ComposerDropPolicy.imageTypeIdentifier(fromRegistered: []))
  }

  // MARK: DroppedImageFile

  func test_pngSignatureSniff() {
    XCTAssertTrue(DroppedImageFile.isPNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
    XCTAssertFalse(DroppedImageFile.isPNG(Data([0xFF, 0xD8, 0xFF])))  // JPEG SOI
    XCTAssertFalse(DroppedImageFile.isPNG(Data()))
  }

  func test_writeMaterializesPNGDataAsTempPNGFile() throws {
    let png = try XCTUnwrap(onePixelBitmap().representation(using: .png, properties: [:]))
    let url = try XCTUnwrap(DroppedImageFile.write(png))
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(url.pathExtension, "png")
    XCTAssertTrue(url.path.contains(DroppedImageFile.directoryName))
    let written = try Data(contentsOf: url)
    XCTAssertTrue(DroppedImageFile.isPNG(written))
  }

  func test_writeReencodesForeignRasterDataToPNG() throws {
    let tiff = try XCTUnwrap(onePixelBitmap().tiffRepresentation)
    XCTAssertFalse(DroppedImageFile.isPNG(tiff))
    let url = try XCTUnwrap(DroppedImageFile.write(tiff))
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(url.pathExtension, "png")
    let written = try Data(contentsOf: url)
    XCTAssertTrue(DroppedImageFile.isPNG(written))
  }

  func test_writeRejectsNonImageData() {
    XCTAssertNil(DroppedImageFile.write(Data([0x00, 0x01, 0x02, 0x03])))
  }

  private func onePixelBitmap() throws -> NSBitmapImageRep {
    try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 1,
      pixelsHigh: 1,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
  }
}
