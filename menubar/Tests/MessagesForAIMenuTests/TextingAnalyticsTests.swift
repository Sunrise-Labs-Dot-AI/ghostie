import XCTest
@testable import MessagesForAIMenu

final class TextingAnalyticsTests: XCTestCase {
  func testDecodesGeneratorAgeConfidenceLabel() throws {
    let json = """
      {
        "schema_version": "1.0",
        "generated_at_ms": 1780624560195,
        "window_label": "Jun 2025 — Jun 2026",
        "window_days": 365,
        "total_sent": 7100,
        "age": {
          "estimated_age": 47,
          "confidence": "low"
        },
        "filters": {
          "excluded_business_1to1_threads": 217
        }
      }
      """

    let report = try JSONDecoder().decode(TextingAnalyticsReport.self, from: Data(json.utf8))

    XCTAssertEqual(report.age?.estimatedAge, 47)
    XCTAssertEqual(report.age?.confidence, "low")
  }

  func testDecodesGeneratorStyleAndEmojiShape() throws {
    let json = """
      {
        "schema_version": "1.0",
        "style": {
          "pct_end_period": 21.5
        },
        "emoji": {
          "pct_messages_with_emoji": 7.2,
          "top": [
            { "emoji": "👍", "count": 12 },
            { "emoji": "🙏", "count": 8 }
          ]
        }
      }
      """

    let report = try JSONDecoder().decode(TextingAnalyticsReport.self, from: Data(json.utf8))

    XCTAssertEqual(report.style?.pctNoTerminalPunct, 78.5)
    XCTAssertEqual(report.emoji?.pctMessagesWithEmoji, 7.2)
    XCTAssertEqual(report.emoji?.topEmoji, ["👍", "🙏"])
  }

  func testDecodesInteractiveDashboardBlocks() throws {
    let json = """
      {
        "schema_version": "1.0",
        "activity_trend": {
          "granularity": "week",
          "rows": [
            {
              "period": "2026-05-25",
              "label": "2026-05-25",
              "sent": 7,
              "received": 9,
              "one_to_one_sent": 5,
              "one_to_one_received": 4,
              "group_sent": 2,
              "group_received": 5
            }
          ]
        },
        "rhythm": {
          "buckets": [
            { "weekday": 1, "hour": 9, "sent": 3, "received": 2, "total": 5 }
          ],
          "peak_sent": { "weekday": 1, "hour": 9, "sent": 3, "received": 2, "total": 5 }
        },
        "conversation_mix": {
          "one_to_one": { "sent": 7, "received": 8 },
          "groups": { "sent": 2, "received": 4 },
          "kinds": {
            "text": { "sent": 8, "received": 10 }
          }
        },
        "comparison": {
          "mode": "previous_period",
          "metrics": [
            {
              "key": "total_sent",
              "label": "Sent",
              "unit": "count",
              "current": 7,
              "previous": 5,
              "delta": 2
            }
          ]
        }
      }
      """

    let report = try JSONDecoder().decode(TextingAnalyticsReport.self, from: Data(json.utf8))

    XCTAssertEqual(report.activityTrend?.granularity, "week")
    XCTAssertEqual(report.activityTrend?.rows?.first?.sent, 7)
    XCTAssertEqual(report.rhythm?.peakSent?.hour, 9)
    XCTAssertEqual(report.conversationMix?.oneToOne?.sent, 7)
    XCTAssertEqual(report.conversationMix?.kinds?["text"]?.received, 10)
    XCTAssertEqual(report.comparison?.metrics?.first?.delta, 2)
  }

  func testDecodesMetadataExtrasBlocks() throws {
    let json = """
      {
        "schema_version": "1.0",
        "initiators": {
          "conversations": 40,
          "you_started": 30,
          "they_started": 10,
          "pct_you_start": 75,
          "per_contact": [
            { "name": "Alice", "conversations": 12, "you_started": 9, "they_started": 3, "pct_you_start": 75 }
          ]
        },
        "streaks": {
          "best": { "name": "Alice", "days": 41, "ended": "2026-03-01" },
          "per_contact": [
            { "name": "Alice", "days": 41, "ended": "2026-03-01" },
            { "name": "Bob", "days": 7, "ended": "2026-01-12" }
          ]
        },
        "double_texts": {
          "double_texts": 120,
          "outbound_messages": 4000,
          "rate_pct": 3,
          "per_contact": [
            { "name": "Bob", "double_texts": 31, "outbound": 800, "rate_pct": 3.9 }
          ]
        },
        "busiest_day": { "date": "2026-01-05", "total": 312, "sent": 150, "received": 162 },
        "hours": {
          "buckets": [
            { "hour": 0, "sent": 4, "received": 1 },
            { "hour": 23, "sent": 9, "received": 12 }
          ],
          "night_owl_pct": 4.2,
          "peak_hour": 21
        },
        "top_share": {
          "total": 100000,
          "people": [
            { "name": "Alice", "count": 20000, "pct": 20 }
          ],
          "others_count": 80000,
          "others_pct": 80
        }
      }
      """

    let report = try JSONDecoder().decode(TextingAnalyticsReport.self, from: Data(json.utf8))

    XCTAssertEqual(report.initiators?.pctYouStart, 75)
    XCTAssertEqual(report.initiators?.perContact?.first?.youStarted, 9)
    XCTAssertEqual(report.streaks?.best?.days, 41)
    XCTAssertEqual(report.streaks?.perContact?.count, 2)
    XCTAssertEqual(report.doubleTexts?.ratePct, 3)
    XCTAssertEqual(report.doubleTexts?.perContact?.first?.doubleTexts, 31)
    XCTAssertEqual(report.busiestDay?.date, "2026-01-05")
    XCTAssertEqual(report.busiestDay?.total, 312)
    XCTAssertEqual(report.hours?.buckets?.count, 2)
    XCTAssertEqual(report.hours?.nightOwlPct, 4.2)
    XCTAssertEqual(report.hours?.peakHour, 21)
    XCTAssertEqual(report.topShare?.people?.first?.pct, 20)
    XCTAssertEqual(report.topShare?.othersCount, 80000)
  }

  func testExtrasBlocksAreOptionalForOlderCachedReports() throws {
    let json = """
      { "schema_version": "1.0", "total_sent": 10 }
      """

    let report = try JSONDecoder().decode(TextingAnalyticsReport.self, from: Data(json.utf8))

    XCTAssertNil(report.initiators)
    XCTAssertNil(report.streaks)
    XCTAssertNil(report.doubleTexts)
    XCTAssertNil(report.busiestDay)
    XCTAssertNil(report.hours)
    XCTAssertNil(report.topShare)
  }
}
