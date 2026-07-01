import XCTest
@testable import MessagesForAIMenu

final class VideoLinkDetectorTests: XCTestCase {
  private func classify(_ s: String) -> VideoLink? {
    URL(string: s).flatMap(VideoLinkDetector.classify)
  }

  func testYouTubeWatchURL() {
    let link = classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    XCTAssertEqual(link?.provider, .youtube)
    XCTAssertEqual(link?.videoID, "dQw4w9WgXcQ")
  }

  func testYouTubeShortURLAndShortsAndEmbed() {
    XCTAssertEqual(classify("https://youtu.be/dQw4w9WgXcQ")?.videoID, "dQw4w9WgXcQ")
    XCTAssertEqual(classify("https://www.youtube.com/shorts/dQw4w9WgXcQ")?.videoID, "dQw4w9WgXcQ")
    XCTAssertEqual(classify("https://www.youtube.com/embed/dQw4w9WgXcQ")?.videoID, "dQw4w9WgXcQ")
    XCTAssertEqual(classify("https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")?.videoID, "dQw4w9WgXcQ")
  }

  func testVimeo() {
    XCTAssertEqual(classify("https://vimeo.com/123456789")?.provider, .vimeo)
    XCTAssertEqual(classify("https://player.vimeo.com/video/987654321")?.videoID, "987654321")
  }

  func testNonVideoLinksAreIgnored() {
    XCTAssertNil(classify("https://example.com/watch?v=dQw4w9WgXcQ"))
    XCTAssertNil(classify("https://www.youtube.com/feed/subscriptions"))
    XCTAssertNil(classify("https://vimeo.com/upgrade")) // non-numeric path
    XCTAssertNil(classify("https://youtu.be/short")) // wrong-length id
  }

  func testThumbnailAndEmbedURLs() {
    let link = classify("https://youtu.be/dQw4w9WgXcQ")
    XCTAssertEqual(link?.thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    XCTAssertEqual(link?.embedURL?.absoluteString, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
  }

  func testDetectExtractsAndDedupesFromText() {
    let body = """
    check this https://youtu.be/dQw4w9WgXcQ and again
    https://www.youtube.com/watch?v=dQw4w9WgXcQ plus https://vimeo.com/123456789
    """
    let links = VideoLinkDetector.detect(in: body)
    // The two YouTube URLs collapse to one (same id); Vimeo is separate.
    XCTAssertEqual(links.count, 2)
    XCTAssertEqual(links.first?.videoID, "dQw4w9WgXcQ")
    XCTAssertTrue(links.contains { $0.provider == .vimeo && $0.videoID == "123456789" })
  }

  func testDetectReturnsEmptyForPlainText() {
    XCTAssertTrue(VideoLinkDetector.detect(in: "no links here, just words").isEmpty)
  }
}
