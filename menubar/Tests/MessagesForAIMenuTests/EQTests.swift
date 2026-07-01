import XCTest
@testable import MessagesForAIMenu

final class EQTests: XCTestCase {
  func testPresetPromptsIncludePersonPlaceholder() {
    XCTAssertFalse(EQPreset.all.isEmpty)
    XCTAssertTrue(EQPreset.all.allSatisfy { $0.prompt.contains("{person}") })
  }

  func testPresetLibraryIsExpandedAndGrouped() {
    XCTAssertGreaterThanOrEqual(EQPreset.all.count, 18)
    XCTAssertEqual(Set(EQPreset.all.map(\.id)).count, EQPreset.all.count, "preset ids must be unique")
    for category in EQPresetCategory.allCases {
      XCTAssertGreaterThanOrEqual(
        EQPreset.presets(in: category).count, 2,
        "category \(category.rawValue) should offer at least two questions"
      )
    }
  }

  func testPresetCategoriesCoverTheBrief() {
    XCTAssertEqual(
      EQPresetCategory.allCases.map(\.rawValue),
      ["Connection", "Conflict & Repair", "Support", "Boundaries", "Celebration & Play", "Growth"]
    )
  }

  func testPresetPromptsStayInReflectiveCoachingRegister() {
    // No diagnosis, no clinical claims — and house style bans em dashes.
    let banned = ["diagnos", "disorder", "clinical", "therapy", "therapist", "attachment style", "\u{2014}"]
    for preset in EQPreset.all {
      let lowered = preset.prompt.lowercased()
      for term in banned {
        XCTAssertFalse(lowered.contains(term), "preset \(preset.id) contains banned term \(term)")
      }
    }
  }

  func testOriginalVettedPresetsSurvive() {
    let ids = Set(EQPreset.all.map(\.id))
    for id in ["better-friend", "bids", "care", "patterns", "repair"] {
      XCTAssertTrue(ids.contains(id), "original vetted preset \(id) should remain")
    }
  }

  func testRelationshipOptionsIncludeOther() {
    XCTAssertFalse(EQRelationshipType.allCases.isEmpty)
    XCTAssertTrue(EQRelationshipType.allCases.contains(.other))
  }

  func testEQUserFacingErrors() {
    XCTAssertEqual(EQController.userFacingError(EQError.noAPIKey), "Add a Claude or ChatGPT API key in Settings first.")
    XCTAssertEqual(EQController.userFacingError(EQError.noPerson), "Choose a person first.")
  }

  func testEQPromptUsesResearchBackedReflectionLenses() {
    let prompt = makePrompt()

    XCTAssertTrue(prompt.contains("Volume is not closeness"))
    XCTAssertTrue(prompt.contains("lower-bound slice"))
    XCTAssertTrue(prompt.contains("Look for bids"))
    XCTAssertTrue(prompt.contains("responsiveness"))
    XCTAssertTrue(prompt.contains("Do not infer loneliness"))
    XCTAssertTrue(prompt.contains("## Evidence Quality"))
    XCTAssertTrue(prompt.contains("## Bids And Responsiveness"))
    XCTAssertTrue(prompt.contains("## Reciprocity, Care, And Repair"))
    XCTAssertTrue(prompt.contains("sample_is_excerpt"))
  }

  func testEQPromptAvoidsOverclaimingForPartnerContexts() {
    let prompt = makePrompt(relationship: "Spouse / partner", totalThreadMessages: 1000)

    XCTAssertTrue(prompt.contains("spouse, partner, family member, or co-parent"))
    XCTAssertTrue(prompt.contains("do not overread silence, logistics, or short messages as decay"))
    XCTAssertTrue(prompt.contains("in-person care seems more appropriate"))
  }

  func testEQPromptAvoidsHouseStyleEmDash() {
    XCTAssertFalse(makePrompt().contains("\u{2014}"))
  }

  private func makePrompt(
    relationship: String = "Friend",
    totalThreadMessages: Int = 20
  ) -> String {
    EQReportPrompt.make(
      person: EQPerson(
        id: 1,
        displayName: "Taylor",
        handle: "+15555550123",
        messageCount: totalThreadMessages,
        lastMessageAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      relationship: relationship,
      contextDepth: .threadArc,
      prompt: EQPreset.all[0].prompt,
      totalThreadMessages: totalThreadMessages,
      messages: [
        EQMessage(
          id: 1,
          fromMe: false,
          body: "Want to catch up soon?",
          sentAt: Date(timeIntervalSince1970: 1_699_999_000)
        ),
        EQMessage(
          id: 2,
          fromMe: true,
          body: "Yes, would love that",
          sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
      ]
    )
  }
}
