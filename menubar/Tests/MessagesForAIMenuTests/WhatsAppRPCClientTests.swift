import XCTest
@testable import MessagesForAIMenu

final class WhatsAppRPCClientTests: XCTestCase {
  func testMinAgeGuardUsesUserFacingMessage() {
    let error = WhatsAppRPCClient.RPCError.rpcError(
      code: -32021,
      message: "staged 1285ms ago, min 5000ms"
    )

    XCTAssertEqual(
      error.userFacingMessage,
      "This draft is still getting ready. Try again in a few seconds."
    )
    XCTAssertEqual(error.localizedDescription, error.userFacingMessage)
    XCTAssertEqual(error.description, "daemon RPC error -32021: staged 1285ms ago, min 5000ms")
  }

  func testReactionTargetNotFoundUsesUserFacingMessage() {
    let error = WhatsAppRPCClient.RPCError.rpcError(
      code: -32029,
      message: "target message is no longer available"
    )

    XCTAssertEqual(error.userFacingMessage, "That message is no longer available.")
    XCTAssertEqual(error.localizedDescription, error.userFacingMessage)
    XCTAssertEqual(
      error.userFacingMessage(for: .reaction),
      "That message is no longer available to react to."
    )
  }

  func testReactionContextRewordsSendBudgetAndGenericFailures() {
    let burst = WhatsAppRPCClient.RPCError.rpcError(code: -32023, message: "burst")
    XCTAssertEqual(
      burst.userFacingMessage(for: .reaction),
      "You've sent a lot at once. Try the reaction again in a minute."
    )

    let dailyCap = WhatsAppRPCClient.RPCError.rpcError(code: -32024, message: "cap")
    XCTAssertEqual(
      dailyCap.userFacingMessage(for: .reaction),
      "Today's WhatsApp send limit has been reached, so the reaction wasn't sent."
    )

    let spacing = WhatsAppRPCClient.RPCError.rpcError(code: -32022, message: "spacing")
    XCTAssertEqual(
      spacing.userFacingMessage(for: .reaction),
      "Ghostie is spacing out sends. Try the reaction again in a moment."
    )

    // The generic fallback must not talk about drafts when a reaction failed.
    let unknown = WhatsAppRPCClient.RPCError.rpcError(code: -39999, message: "?")
    XCTAssertEqual(
      unknown.userFacingMessage(for: .reaction),
      "WhatsApp couldn't add that reaction. Try again."
    )
    XCTAssertEqual(unknown.userFacingMessage, "WhatsApp couldn't send this draft. Try again.")

    let sendFailed = WhatsAppRPCClient.RPCError.rpcError(code: -32025, message: "boom")
    XCTAssertEqual(
      sendFailed.userFacingMessage(for: .reaction),
      "WhatsApp couldn't add that reaction. Check WhatsApp and try again."
    )
  }
}
