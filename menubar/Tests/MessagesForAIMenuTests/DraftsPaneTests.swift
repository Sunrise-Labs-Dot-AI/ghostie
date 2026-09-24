import Foundation
import SwiftUI
import XCTest
@testable import MessagesForAIMenu

final class DraftsPaneTests: XCTestCase {
  func test_groupingCombinesDraftsByThreadAndOrdersNewestThreadFirst() throws {
    let firstAllie = try draft(
      id: "a1",
      handle: "+14045550100",
      name: "Allie",
      body: "first",
      stagedAt: "2026-06-01T12:00:00.000Z"
    )
    let bob = try draft(
      id: "b1",
      handle: "+14045550200",
      name: "Bob",
      body: "newer",
      stagedAt: "2026-06-01T14:00:00.000Z"
    )
    let secondAllie = try draft(
      id: "a2",
      handle: "+14045550100",
      name: "Allie",
      body: "second",
      stagedAt: "2026-06-01T13:00:00.000Z"
    )

    let threads = DraftThread.group([firstAllie, bob, secondAllie])

    XCTAssertEqual(threads.map(\.displayName), ["Bob", "Allie"])
    XCTAssertEqual(threads[1].oldestFirstDrafts.map(\.id), ["a1", "a2"])
    XCTAssertEqual(threads[1].pendingCount, 2)
  }

  func test_groupingSeparatesPlatformsForSameHandle() throws {
    let imessage = try draft(id: "i1", handle: "+14045550100", platform: nil)
    let whatsapp = try draft(id: "w1", handle: "+14045550100", platform: .whatsapp)

    let threads = DraftThread.group([imessage, whatsapp])

    XCTAssertEqual(threads.count, 2)
    XCTAssertEqual(Set(threads.map(\.platform)), [.imessage, .whatsapp])
  }

  func test_groupingKeepsScheduledAndDraftMessagesTogether() throws {
    let draftMessage = try draft(id: "d1", stagedAt: "2026-06-01T12:00:00.000Z")
    let scheduledMessage = try draft(
      id: "s1",
      stagedAt: "2026-06-01T13:00:00.000Z",
      scheduledAt: "2026-06-02T16:00:00.000Z"
    )

    let thread = try XCTUnwrap(DraftThread.group([draftMessage, scheduledMessage]).first)

    XCTAssertEqual(thread.draftCount, 1)
    XCTAssertEqual(thread.scheduledCount, 1)
    XCTAssertEqual(thread.oldestFirstDrafts.map(\.id), ["d1", "s1"])
  }

  func test_plainDraftQueueExcludesScheduledMessages() throws {
    let draftMessage = try draft(id: "d1", stagedAt: "2026-06-01T12:00:00.000Z")
    let scheduledMessage = try draft(
      id: "s1",
      stagedAt: "2026-06-01T13:00:00.000Z",
      scheduledAt: "2026-06-02T16:00:00.000Z"
    )

    let visible = DraftThread.queueDrafts(
      [draftMessage, scheduledMessage],
      scope: .plainDrafts
    )

    XCTAssertEqual(visible.map(\.id), ["d1"])
  }

  func test_draftThreadSubtitleHidesHandleWhenRecipientNameExists() throws {
    let named = try draft(id: "named", handle: "+14045550100", name: "Allie")
    let unnamed = try draft(id: "unnamed", handle: "+14045550200", name: nil)

    let threads = DraftThread.group([named, unnamed])
    let namedThread = try XCTUnwrap(threads.first { $0.displayName == "Allie" })
    let unnamedThread = try XCTUnwrap(threads.first { $0.displayName == "+14045550200" })

    XCTAssertEqual(namedThread.subtitle, "")
    XCTAssertEqual(unnamedThread.subtitle, "+14045550200")
  }

  func test_threadMessageCacheDoesNotReuseEmptyWhatsAppRead() {
    let date = Date()

    XCTAssertFalse(
      ThreadMessageCachePolicy.shouldReuse(
        platform: .whatsapp,
        cachedMessages: [],
        cachedLastMessageDate: date,
        currentLastMessageDate: date
      )
    )
    XCTAssertTrue(
      ThreadMessageCachePolicy.shouldReuse(
        platform: .imessage,
        cachedMessages: [],
        cachedLastMessageDate: date,
        currentLastMessageDate: date
      )
    )
  }

  func test_threadMessageCacheDoesNotStoreEmptyWhatsAppRead() {
    XCTAssertFalse(ThreadMessageCachePolicy.shouldStore(platform: .whatsapp, messages: []))
    XCTAssertTrue(ThreadMessageCachePolicy.shouldStore(platform: .imessage, messages: []))
  }

  func test_threadPreloadPolicySelectsTopEightAndSkipsFreshCache() {
    let conversations = (0..<10).map { index in
      testConversation(id: "imessage-\(index)", lastMessageDate: Date(timeIntervalSince1970: Double(index)))
    }
    let fresh = ThreadMessageCacheEntry(
      messages: [testMessage(sentAt: "2026-06-01T12:00:00.000Z")],
      lastMessageDate: conversations[0].recent.lastMessageDate,
      hasLoadedAllAvailableHistory: true
    )

    let candidates = ThreadPreloadPolicy.candidates(
      conversations,
      cache: [conversations[0].id: fresh],
      inFlight: [conversations[1].id],
      now: Date()
    )

    XCTAssertEqual(candidates.map(\.id), Array(2..<8).map { "imessage-\($0)" })
  }

  func test_messageCachePruningDropsExpiredAndKeepsMostRecentAccesses() {
    let now = Date()
    let expired = ThreadMessageCacheEntry(
      messages: [testMessage()],
      lastMessageDate: now,
      hasLoadedAllAvailableHistory: true,
      cachedAt: now.addingTimeInterval(-ThreadPreloadPolicy.ttl - 1),
      lastAccessedAt: now
    )
    let older = ThreadMessageCacheEntry(
      messages: [testMessage()],
      lastMessageDate: now,
      hasLoadedAllAvailableHistory: true,
      cachedAt: now,
      lastAccessedAt: now.addingTimeInterval(-20)
    )
    let newer = ThreadMessageCacheEntry(
      messages: [testMessage()],
      lastMessageDate: now,
      hasLoadedAllAvailableHistory: true,
      cachedAt: now,
      lastAccessedAt: now.addingTimeInterval(-5)
    )

    let pruned = MessageCachePruningPolicy.pruned(
      ["expired": expired, "older": older, "newer": newer],
      now: now,
      maxEntries: 1
    )

    XCTAssertEqual(Array(pruned.keys), ["newer"])
  }

  func test_conversationSearchFiltersByTitleHandleAndMultipleTerms() {
    let conversations = [
      testConversation(id: "ryan", title: "Ryan Example", subtitle: "", handle: "+12155550121"),
      testConversation(id: "pharmacy", title: "269679", subtitle: "269679", handle: "269679"),
      testConversation(id: "parents", title: "O’Malley Parents ‘25-‘26", subtitle: "", handle: "120363000000000001@g.us")
    ]

    XCTAssertEqual(ConversationSearchPolicy.filtered(conversations, query: "").map(\.id), ["ryan", "pharmacy", "parents"])
    XCTAssertEqual(ConversationSearchPolicy.filtered(conversations, query: "example").map(\.id), ["ryan"])
    XCTAssertEqual(ConversationSearchPolicy.filtered(conversations, query: "2155550").map(\.id), ["ryan"])
    XCTAssertEqual(ConversationSearchPolicy.filtered(conversations, query: "omalley parents").map(\.id), ["parents"])
    XCTAssertEqual(ConversationSearchPolicy.filtered(conversations, query: "amazon").map(\.id), [])
  }

  func test_transcriptScrollPolicyGuardsTopLoaderUntilInitialSnap() {
    XCTAssertFalse(TranscriptScrollPolicy.shouldTriggerTopHistoryLoader(initialBottomSnapCompleted: false))
    XCTAssertTrue(TranscriptScrollPolicy.shouldTriggerTopHistoryLoader(initialBottomSnapCompleted: true))
    XCTAssertEqual(TranscriptScrollPolicy.restoreAnchorAfterPrepend(previousOldestVisibleID: "m1"), "m1")
  }

  func test_messageNotificationPolicyFiltersFocusBaselineDirectionAndFreshness() {
    let now = Date()
    let freshInbound = testMessage(fromMe: false, sentAt: iso(now.addingTimeInterval(-30)))
    let oldInbound = testMessage(fromMe: false, sentAt: iso(now.addingTimeInterval(-600)))
    let outbound = testMessage(fromMe: true, sentAt: iso(now))

    XCTAssertTrue(MessageNotificationPolicy.shouldNotify(
      appIsActive: false,
      notificationsEnabled: true,
      message: freshInbound,
      baselineDate: now.addingTimeInterval(-60),
      now: now
    ))
    XCTAssertFalse(MessageNotificationPolicy.shouldNotify(appIsActive: true, notificationsEnabled: true, message: freshInbound, baselineDate: nil, now: now))
    XCTAssertFalse(MessageNotificationPolicy.shouldNotify(appIsActive: false, notificationsEnabled: false, message: freshInbound, baselineDate: nil, now: now))
    XCTAssertFalse(MessageNotificationPolicy.shouldNotify(appIsActive: false, notificationsEnabled: true, message: outbound, baselineDate: nil, now: now))
    XCTAssertFalse(MessageNotificationPolicy.shouldNotify(appIsActive: false, notificationsEnabled: true, message: oldInbound, baselineDate: nil, now: now))
    XCTAssertFalse(MessageNotificationPolicy.shouldNotify(appIsActive: false, notificationsEnabled: true, message: freshInbound, baselineDate: now, now: now))
  }

  func test_messageNotificationPreviewStyles() {
    let message = testMessage(body: "First line")

    XCTAssertEqual(
      MessageNotificationPolicy.preview(style: .shortPreview, conversationTitle: "Ryan", platform: .imessage, messages: [message]).body,
      "First line"
    )
    XCTAssertEqual(
      MessageNotificationPolicy.preview(style: .threadOnly, conversationTitle: "Ryan", platform: .imessage, messages: [message]).body,
      "New iMessage message"
    )
    XCTAssertEqual(
      MessageNotificationPolicy.preview(style: .countOnly, conversationTitle: "Ryan", platform: .whatsapp, messages: [message, message]).body,
      "2 new WhatsApp messages"
    )
  }

  func test_messageNotificationPolicyUsesWorkPersonalVisibility() {
    XCTAssertTrue(MessageNotificationPolicy.visibleForWorkPersonal(enabled: false, filter: .work, personLabel: .personal))
    XCTAssertTrue(MessageNotificationPolicy.visibleForWorkPersonal(enabled: true, filter: .work, personLabel: .both))
    XCTAssertFalse(MessageNotificationPolicy.visibleForWorkPersonal(enabled: true, filter: .work, personLabel: .personal))
    XCTAssertTrue(MessageNotificationPolicy.visibleForWorkPersonal(enabled: true, filter: .all, personLabel: .unknown))
  }

  func test_contextMessagePaginationCursorUsesPlatformNativeTimestamps() throws {
    let message = ContextMessage(
      from_me: true,
      sender_handle: nil,
      sender_name: nil,
      body: "hello",
      sent_at: "2026-06-01T12:00:00.000Z"
    )

    XCTAssertEqual(message.paginationCursor(platform: .whatsapp), 1_780_315_200_000)
    XCTAssertEqual(message.paginationCursor(platform: .imessage), 802_008_000_000_000_000)
  }

  func test_contextMessagePaginationCursorMissingDateReturnsNil() {
    let message = ContextMessage(
      from_me: true,
      sender_handle: nil,
      sender_name: nil,
      body: "hello",
      sent_at: nil
    )

    XCTAssertNil(message.paginationCursor(platform: .imessage))
  }

  func test_iMessageTapbacksAttachToTargetMessage() {
    let message = ContextMessage(
      guid: "message-guid-1",
      from_me: true,
      sender_handle: nil,
      sender_name: nil,
      body: "hello",
      sent_at: "2026-06-01T12:00:00.000Z"
    )
    let reaction = MessageReaction(
      kind: .loved,
      from_me: false,
      sender_handle: "+15555550100",
      sender_name: "Cole",
      sent_at: "2026-06-01T12:01:00.000Z"
    )

    let rendered = RecentComposeThread.attachTapbacksForTesting(
      messages: [message],
      reactionsByMessageGUID: ["message-guid-1": [reaction]]
    )

    XCTAssertEqual(rendered.count, 1)
    XCTAssertEqual(rendered[0].body, "hello")
    XCTAssertEqual(rendered[0].reactions, [reaction])
  }

  func test_iMessageTapbacksSortDeterministicallyAndRemovedTypesAreRecognized() {
    XCTAssertEqual(RecentComposeThread.tapbackKindForTesting(2000), .loved)
    XCTAssertEqual(RecentComposeThread.tapbackKindForTesting(2001), .liked)
    XCTAssertTrue(RecentComposeThread.isTapbackForTesting(3001))

    let message = ContextMessage(
      guid: "message-guid-1",
      from_me: false,
      sender_handle: "+15555550100",
      sender_name: "Cole",
      body: "hello",
      sent_at: "2026-06-01T12:00:00.000Z"
    )
    let later = MessageReaction(kind: .liked, from_me: true, sender_handle: nil, sender_name: nil, sent_at: "2026-06-01T12:03:00.000Z")
    let earlier = MessageReaction(kind: .questioned, from_me: true, sender_handle: nil, sender_name: nil, sent_at: "2026-06-01T12:02:00.000Z")

    let rendered = RecentComposeThread.attachTapbacksForTesting(
      messages: [message],
      reactionsByMessageGUID: ["message-guid-1": [later, earlier]]
    )

    XCTAssertEqual(rendered[0].reactions, [earlier, later])
  }

  func test_groupingKeepsSentAndPendingMessagesInSameThread() throws {
    let pending = try draft(
      id: "p1",
      stagedAt: "2026-06-01T12:00:00.000Z"
    )
    let sent = try draft(
      id: "sent1",
      stagedAt: "2026-06-01T11:00:00.000Z",
      sentAt: "2026-06-01T12:30:00.000Z"
    )

    let thread = try XCTUnwrap(DraftThread.group([pending, sent]).first)

    XCTAssertEqual(thread.pendingDrafts.map(\.id), ["p1"])
    XCTAssertEqual(thread.sentDrafts.map(\.id), ["sent1"])
    XCTAssertEqual(thread.pendingCount, 1)
    XCTAssertEqual(thread.sentCount, 1)
  }

  func test_queueDraftsDropsSentOnlyThreads() throws {
    let sent = try draft(
      id: "sent1",
      stagedAt: "2026-06-01T11:00:00.000Z",
      sentAt: "2026-06-01T12:30:00.000Z"
    )

    let visible = DraftThread.queueDrafts(
      [sent],
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z"))
    )

    XCTAssertTrue(visible.isEmpty)
  }

  func test_queueDraftsKeepsRecentSentOnlyWhenThreadStillHasPendingWork() throws {
    let pending = try draft(
      id: "p1",
      stagedAt: "2026-06-01T12:00:00.000Z"
    )
    let sent = try draft(
      id: "sent1",
      stagedAt: "2026-06-01T11:00:00.000Z",
      sentAt: "2026-06-01T12:30:00.000Z"
    )
    let otherSent = try draft(
      id: "sent2",
      handle: "+14045550200",
      name: "Bob",
      stagedAt: "2026-06-01T11:00:00.000Z",
      sentAt: "2026-06-01T12:30:00.000Z"
    )

    let visible = DraftThread.queueDrafts(
      [pending, sent, otherSent],
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z"))
    )

    XCTAssertEqual(visible.map(\.id), ["p1", "sent1"])
  }

  func test_contextMessagesDeduplicateAcrossMultipleDrafts() throws {
    let context = """
      [
        { "from_me": false, "sender_handle": "+14045550100", "sender_name": "Allie", "body": "see you soon", "sent_at": "2026-06-01T11:00:00.000Z" }
      ]
    """
    let first = try draft(id: "a1", contextJSON: context, stagedAt: "2026-06-01T12:00:00.000Z")
    let second = try draft(id: "a2", contextJSON: context, stagedAt: "2026-06-01T13:00:00.000Z")

    let thread = try XCTUnwrap(DraftThread.group([first, second]).first)

    XCTAssertEqual(thread.contextMessages.count, 1)
    XCTAssertEqual(thread.contextMessages.first?.body, "see you soon")
  }

  func test_messageConversationMergesDraftByHandleWhenThreadIDDoesNotMatch() throws {
    let pending = try draft(
      id: "d1",
      handle: "+14045550100",
      name: "Allie",
      stagedAt: "2026-06-01T12:00:00.000Z"
    )
    let draftThreads = DraftThread.group([pending])
    let recent = RecentComposeThread(
      id: "imessage-42",
      platform: .imessage,
      handle: "+14045550100",
      title: "Allie",
      subtitle: "+14045550100",
      threadID: 42,
      lastMessageDate: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T11:00:00Z"))
    )

    let conversations = MessageConversation.merge(
      lookback: .allTime,
      draftThreads: draftThreads,
      recents: [recent]
    )

    XCTAssertEqual(conversations.count, 1)
    XCTAssertEqual(conversations.first?.recent.id, "imessage-42")
    XCTAssertEqual(conversations.first?.draftThread?.newestDraft.id, "d1")
  }

  func test_conversationHandleMatcher_matchesAcrossFormattingVariants() {
    // The Birthday lab's "Open conversation" deep link: a birthday person's
    // handles must match a conversation by CANONICAL key, so "+1 (404) 555-0100"
    // on the contact card finds the "+14045550100" thread.
    let allie = MessageConversation(
      recent: RecentComposeThread(
        id: "imessage-1", platform: .imessage, handle: "+14045550100",
        title: "Allie", subtitle: "", threadID: 1, lastMessageDate: Date()
      ),
      draftThread: nil
    )
    let bob = MessageConversation(
      recent: RecentComposeThread(
        id: "imessage-2", platform: .imessage, handle: "bob@example.com",
        title: "Bob", subtitle: "", threadID: 2, lastMessageDate: Date()
      ),
      draftThread: nil
    )

    XCTAssertEqual(
      ConversationHandleMatcher.match(handles: ["+1 (404) 555-0100"], in: [allie, bob])?.id,
      "imessage-1"
    )
    XCTAssertEqual(
      ConversationHandleMatcher.match(handles: ["BOB@example.com"], in: [allie, bob])?.id,
      "imessage-2"
    )
    XCTAssertNil(ConversationHandleMatcher.match(handles: ["+19998887777"], in: [allie, bob]))
    XCTAssertNil(ConversationHandleMatcher.match(handles: [], in: [allie, bob]))
  }

  func test_messageSendTargetCapturesVisibleConversationIdentity() throws {
    let conversation = MessageConversation(
      recent: RecentComposeThread(
        id: "imessage-318",
        platform: .imessage,
        handle: "+13015550194",
        title: "Ryan Example",
        subtitle: "",
        threadID: 318,
        lastMessageDate: Date()
      ),
      draftThread: nil
    )

    let target = MessageSendTarget(conversation: conversation)

    XCTAssertEqual(target.conversationID, "imessage-318")
    XCTAssertEqual(target.platform, .imessage)
    XCTAssertEqual(target.handle, "+13015550194")
    XCTAssertEqual(target.displayName, "Ryan Example")
    XCTAssertEqual(target.recipientName, "Ryan Example")
    XCTAssertEqual(target.threadID, 318)
    XCTAssertTrue(target.isCurrent(conversationID: "imessage-318"))
  }

  func test_messageSendTargetRejectsStaleConversationID() throws {
    let seorah = MessageConversation(
      recent: RecentComposeThread(
        id: "whatsapp-120363000000000001@g.us",
        platform: .whatsapp,
        handle: "120363000000000001@g.us",
        title: "O’Malley Parents ‘25-‘26",
        subtitle: "",
        threadID: nil,
        lastMessageDate: Date()
      ),
      draftThread: nil
    )

    let target = MessageSendTarget(conversation: seorah)

    XCTAssertFalse(target.isCurrent(conversationID: "imessage-318"))
  }

  func test_enterSendingTextViewCoordinatorRefreshesSubmitClosure() {
    var submissions: [String] = []
    let coordinator = EnterSendingTextView.Coordinator(
      text: .constant(""),
      measuredHeight: .constant(22),
      onSubmit: { submissions.append("old") }
    )

    coordinator.update {
      submissions.append("new")
    }
    coordinator.submit()

    XCTAssertEqual(submissions, ["new"])
  }

  func test_whatsAppMentionFormatterRendersKnownNumericTags() {
    let rendered = WhatsAppMentionFormatter.render(
      "@100000000000001 @200000000000002 if you wanted to get a jeep",
      namesByJIDPrefix: [
        "100000000000001": "Morgan Lee",
        "200000000000002": "Alex"
      ]
    )

    XCTAssertEqual(rendered, "@Morgan Lee @Alex if you wanted to get a jeep")
  }

  func test_whatsAppMentionFormatterLeavesUnknownTagsAlone() {
    let rendered = WhatsAppMentionFormatter.render(
      "ping @100000000000001 and @999999999999999",
      namesByJIDPrefix: ["100000000000001": "Morgan Lee"]
    )

    XCTAssertEqual(rendered, "ping @Morgan Lee and @999999999999999")
  }

  func test_whatsAppThreadRPCDecodeReturnsChronologicalReadableMessages() throws {
    let json = """
      {
        "messages": [
          {
            "message_id": "new",
            "thread_jid": "group@g.us",
            "sender_jid": "222@s.whatsapp.net",
            "sender_name": "Alex",
            "from_me": false,
            "ts": 1800000001000,
            "body": "newer"
          },
          {
            "message_id": "blank",
            "thread_jid": "group@g.us",
            "sender_jid": "111@s.whatsapp.net",
            "sender_name": "Pete",
            "from_me": false,
            "ts": 1800000000500,
            "body": "   "
          },
          {
            "message_id": "old",
            "thread_jid": "group@g.us",
            "sender_jid": "111@s.whatsapp.net",
            "sender_name": "Pete",
            "from_me": false,
            "ts": 1800000000000,
            "body": "older"
          }
        ]
      }
      """

    let messages = try WhatsAppRPCClient.decodeThreadMessages(Data(json.utf8))

    XCTAssertEqual(messages.map(\.body), ["older", "newer"])
    XCTAssertEqual(messages.first?.sender_name, "Pete")
    XCTAssertEqual(messages.first?.sender_handle, "111@s.whatsapp.net")
  }

  func test_preferredDisplayTitleUsesFullContactNameForFirstNameOnlyChat() {
    XCTAssertEqual(
      RecentComposeThread.preferredDisplayTitle(
        chatName: "Paul",
        resolvedName: "Paul Example",
        fallback: "+16780571484304"
      ),
      "Paul Example"
    )
  }

  func test_preferredDisplayTitleKeepsCustomChatNameWhenContactDoesNotExtendIt() {
    XCTAssertEqual(
      RecentComposeThread.preferredDisplayTitle(
        chatName: "Mom",
        resolvedName: "Alice Smith",
        fallback: "+14045550100"
      ),
      "Mom"
    )
  }

  func test_senderLabelPolicyHidesNamesInSinglePersonThreads() {
    let message = ContextMessage(
      from_me: false,
      sender_handle: "+13015550100",
      sender_name: "Tim",
      body: "Nice nice nice",
      sent_at: "2026-06-07T21:27:00.000Z"
    )

    XCTAssertFalse(
      SenderLabelPolicy.shouldShowSender(
        isGroupConversation: false,
        message: message,
        previous: nil
      )
    )
  }

  func test_senderLabelPolicyShowsChangedIncomingSenderInGroups() {
    let first = ContextMessage(
      from_me: false,
      sender_handle: "111@lid",
      sender_name: "Alex",
      body: "First",
      sent_at: "2026-06-07T21:27:00.000Z"
    )
    let second = ContextMessage(
      from_me: false,
      sender_handle: "222@lid",
      sender_name: "James",
      body: "Second",
      sent_at: "2026-06-07T21:28:00.000Z"
    )

    XCTAssertTrue(
      SenderLabelPolicy.shouldShowSender(
        isGroupConversation: true,
        message: second,
        previous: first
      )
    )
  }

  func test_inlineFailedDraftPolicyReusesOnlySameConversationDraft() throws {
    let failed = try draft(id: "failed", threadID: 42)
    let other = try draft(id: "other", handle: "+14045550200", threadID: 99)
    let recent = recent(handle: "+14045550100", threadID: 42)

    let reusable = InlineFailedDraftPolicy.reusableDraft(
      id: "failed",
      drafts: [other, failed],
      conversation: recent
    )

    XCTAssertEqual(reusable?.id, "failed")
  }

  func test_inlineFailedDraftPolicyRejectsSameHandleDifferentIMessageThread() throws {
    let failed = try draft(id: "failed", threadID: 99)
    let recent = recent(handle: "+14045550100", threadID: 42)

    XCTAssertNil(
      InlineFailedDraftPolicy.reusableDraft(
        id: "failed",
        drafts: [failed],
        conversation: recent
      )
    )
  }

  func test_inlineFailedDraftPolicyRejectsFailedDraftFromDifferentVisibleConversation() throws {
    let seorahFailedDraft = try draft(
      id: "failed",
      handle: "120363000000000001@g.us",
      name: "O’Malley Parents ‘25-‘26",
      platform: .whatsapp
    )
    let ryan = recent(handle: "+13015550194", threadID: 318, platform: .imessage)

    XCTAssertNil(
      InlineFailedDraftPolicy.reusableDraft(
        id: "failed",
        drafts: [seorahFailedDraft],
        conversation: ryan
      )
    )
  }

  func test_inlineFailedDraftPolicyRejectsSentDraft() throws {
    let sent = try draft(
      id: "failed",
      threadID: 42,
      sentAt: "2026-06-01T12:30:00.000Z"
    )
    let recent = recent(handle: "+14045550100", threadID: 42)

    XCTAssertNil(
      InlineFailedDraftPolicy.reusableDraft(
        id: "failed",
        drafts: [sent],
        conversation: recent
      )
    )
  }

  func test_optimisticDirectMessageReconcilesWhenTranscriptContainsSentBody() throws {
    let target = MessageSendTarget(conversation: MessageConversation(
      recent: recent(handle: "+14045550100", threadID: 42),
      draftThread: nil
    ))
    let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))
    let optimistic = OptimisticDirectMessage(
      id: "optimistic-1",
      target: target,
      body: "that's amazing",
      createdAt: createdAt,
      state: .sent,
      errorMessage: nil
    )
    let transcript = [
      ContextMessage(
        from_me: true,
        sender_handle: nil,
        sender_name: nil,
        body: "that's amazing",
        sent_at: "2026-06-01T12:00:02.000Z"
      )
    ]

    XCTAssertTrue(OptimisticDirectMessageReconciler.transcriptContains(optimistic, transcript: transcript))
    XCTAssertTrue(
      OptimisticDirectMessageReconciler.unreconciled(
        optimisticMessages: [optimistic],
        transcript: transcript
      ).isEmpty
    )
  }

  func test_optimisticDirectMessageDoesNotReconcileIncomingOrDifferentBody() throws {
    let target = MessageSendTarget(conversation: MessageConversation(
      recent: recent(handle: "+14045550100", threadID: 42),
      draftThread: nil
    ))
    let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))
    let optimistic = OptimisticDirectMessage(
      id: "optimistic-1",
      target: target,
      body: "typed by me",
      createdAt: createdAt,
      state: .sending,
      errorMessage: nil
    )
    let transcript = [
      ContextMessage(
        from_me: false,
        sender_handle: "+14045550100",
        sender_name: "Allie",
        body: "typed by me",
        sent_at: "2026-06-01T12:00:02.000Z"
      ),
      ContextMessage(
        from_me: true,
        sender_handle: nil,
        sender_name: nil,
        body: "different",
        sent_at: "2026-06-01T12:00:03.000Z"
      )
    ]

    XCTAssertFalse(OptimisticDirectMessageReconciler.transcriptContains(optimistic, transcript: transcript))
  }

  func test_inlineComposerLayoutMetricsKeepControlsAndInputAligned() {
    XCTAssertEqual(InlineComposerLayoutMetrics.controlSize, 30)
    XCTAssertEqual(
      InlineComposerLayoutMetrics.textMinHeight + (InlineComposerLayoutMetrics.textVerticalPadding * 2),
      InlineComposerLayoutMetrics.controlSize
    )
    XCTAssertEqual(InlineComposerLayoutMetrics.cornerRadius, InlineComposerLayoutMetrics.controlSize / 2)
  }

  func test_directSendReconcilerIgnoresEmptyFetchAndKeepsOptimisticBubble() throws {
    let optimistic = try optimisticMessage(body: "sent text")
    let current = [testMessage(fromMe: false, body: "old", sentAt: "2026-06-01T11:59:00.000Z")]

    let result = DirectSendTranscriptReconciler.reconcile(
      currentMessages: current,
      optimisticMessages: [optimistic],
      loadedMessages: [],
      optimisticID: optimistic.id
    )

    XCTAssertFalse(result.shouldApply)
    XCTAssertEqual(result.messages, current)
    XCTAssertEqual(result.optimisticMessages, [optimistic])
    XCTAssertFalse(result.isSettled)
    XCTAssertFalse(result.shouldSnapToBottom)
  }

  func test_directSendReconcilerIgnoresStaleFetchWithoutSentBody() throws {
    let optimistic = try optimisticMessage(body: "sent text")
    let current = [
      testMessage(fromMe: false, body: "old", sentAt: "2026-06-01T11:59:00.000Z"),
      testMessage(fromMe: false, body: "newer current", sentAt: "2026-06-01T12:05:00.000Z")
    ]
    let staleFetch = [
      testMessage(fromMe: false, body: "old", sentAt: "2026-06-01T11:59:00.000Z")
    ]

    let result = DirectSendTranscriptReconciler.reconcile(
      currentMessages: current,
      optimisticMessages: [optimistic],
      loadedMessages: staleFetch,
      optimisticID: optimistic.id
    )

    XCTAssertFalse(result.shouldApply)
    XCTAssertEqual(result.messages, current)
    XCTAssertEqual(result.optimisticMessages, [optimistic])
  }

  func test_directSendReconcilerMergesSentTranscriptAndClearsOptimisticBubble() throws {
    let optimistic = try optimisticMessage(body: "sent text")
    let current = [
      testMessage(fromMe: false, body: "older loaded history", sentAt: "2026-06-01T11:45:00.000Z"),
      testMessage(fromMe: false, body: "old", sentAt: "2026-06-01T11:59:00.000Z")
    ]
    let sentTranscript = [
      testMessage(fromMe: false, body: "old", sentAt: "2026-06-01T11:59:00.000Z"),
      testMessage(fromMe: true, body: "sent text", sentAt: "2026-06-01T12:00:02.000Z")
    ]

    let result = DirectSendTranscriptReconciler.reconcile(
      currentMessages: current,
      optimisticMessages: [optimistic],
      loadedMessages: sentTranscript,
      optimisticID: optimistic.id
    )

    XCTAssertTrue(result.shouldApply)
    XCTAssertEqual(result.messages.map(\.body), ["older loaded history", "old", "sent text"])
    XCTAssertTrue(result.optimisticMessages.isEmpty)
    XCTAssertTrue(result.isSettled)
    XCTAssertTrue(result.shouldSnapToBottom)
  }

  func test_directSendReconcilerMergesAdvancedFetchButKeepsOptimisticBubble() throws {
    let optimistic = try optimisticMessage(body: "sent text")
    let current = [
      testMessage(fromMe: false, body: "old", sentAt: "2026-06-01T11:59:00.000Z")
    ]
    let advancedFetch = [
      testMessage(fromMe: false, body: "new inbound", sentAt: "2026-06-01T12:03:00.000Z")
    ]

    let result = DirectSendTranscriptReconciler.reconcile(
      currentMessages: current,
      optimisticMessages: [optimistic],
      loadedMessages: advancedFetch,
      optimisticID: optimistic.id
    )

    XCTAssertTrue(result.shouldApply)
    XCTAssertEqual(result.messages.map(\.body), ["old", "new inbound"])
    XCTAssertEqual(result.optimisticMessages, [optimistic])
    XCTAssertFalse(result.isSettled)
    XCTAssertTrue(result.shouldSnapToBottom)
  }

  func test_transcriptScrollPolicySnapsOnlyForDirectSendReconciliationChanges() {
    XCTAssertFalse(
      TranscriptScrollPolicy.shouldSnapAfterDirectSendReconciliation(
        optimisticRemoved: false,
        messagesChanged: false
      )
    )
    XCTAssertTrue(
      TranscriptScrollPolicy.shouldSnapAfterDirectSendReconciliation(
        optimisticRemoved: true,
        messagesChanged: false
      )
    )
    XCTAssertTrue(
      TranscriptScrollPolicy.shouldSnapAfterDirectSendReconciliation(
        optimisticRemoved: false,
        messagesChanged: true
      )
    )
  }

  func test_directSendAuditHashDoesNotExposeBody() {
    let hash = DraftSender.bodySHA256("that's amazing! I hope you're having the most amazing time")

    XCTAssertEqual(hash.count, 64)
    XCTAssertFalse(hash.contains("amazing"))
  }

  private func recent(
    handle: String,
    threadID: Int?,
    platform: Platform = .imessage
  ) -> RecentComposeThread {
    RecentComposeThread(
      id: "\(platform.rawValue)-\(threadID.map(String.init) ?? handle)",
      platform: platform,
      handle: handle,
      title: "Allie",
      subtitle: handle,
      threadID: threadID,
      lastMessageDate: Date()
    )
  }

  private func testConversation(
    id: String,
    title: String? = nil,
    subtitle: String = "",
    handle: String = "+14045550100",
    platform: Platform = .imessage,
    lastMessageDate: Date? = Date()
  ) -> MessageConversation {
    MessageConversation(
      recent: RecentComposeThread(
        id: id,
        platform: platform,
        handle: handle,
        title: title ?? id,
        subtitle: subtitle,
        threadID: 42,
        lastMessageDate: lastMessageDate
      ),
      draftThread: nil
    )
  }

  private func testMessage(
    fromMe: Bool = false,
    body: String = "hello",
    sentAt: String = "2026-06-01T12:00:00.000Z"
  ) -> ContextMessage {
    ContextMessage(
      from_me: fromMe,
      sender_handle: fromMe ? nil : "+14045550100",
      sender_name: fromMe ? nil : "Allie",
      body: body,
      sent_at: sentAt
    )
  }

  private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func optimisticMessage(body: String, id: String = "optimistic-1") throws -> OptimisticDirectMessage {
    let target = MessageSendTarget(conversation: MessageConversation(
      recent: recent(handle: "+14045550100", threadID: 42),
      draftThread: nil
    ))
    return OptimisticDirectMessage(
      id: id,
      target: target,
      body: body,
      createdAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")),
      state: .sent,
      errorMessage: nil
    )
  }

  private func draft(
    id: String,
    handle: String = "+14045550100",
    name: String? = "Allie",
    body: String = "hello",
    platform: Platform? = nil,
    contextJSON: String = "[]",
    stagedAt: String = "2026-06-01T12:00:00.000Z",
    threadID: Int? = nil,
    sentAt: String? = nil,
    scheduledAt: String? = nil
  ) throws -> Draft {
    let nameField = name.map { "\"\($0)\"" } ?? "null"
    let platformField = platform.map { ", \"platform\": \"\($0.rawValue)\"" } ?? ""
    let sentField = sentAt.map { "\"\($0)\"" } ?? "null"
    let scheduledField = scheduledAt.map { "\"\($0)\"" } ?? "null"
    let threadField = threadID.map(String.init) ?? "null"
    let json = """
    {
      "id": "\(id)",
      "to_handle": "\(handle)",
      "to_handle_name": \(nameField),
      "body": "\(body)",
      "in_reply_to_thread_id": \(threadField),
      "staged_at": "\(stagedAt)",
      "sent_at": \(sentField),
      "send_service": null,
      "source": "test",
      "context_messages": \(contextJSON),
      "context_diagnostic": null,
      "scheduled_send_at": \(scheduledField),
      "schedule_approved": \(scheduledAt == nil ? "null" : "true")\(platformField)
    }
    """
    return try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
  }

  // MARK: - Partial-delivery copy (issue #9)

  /// The number the user reads has to be the honest one: failures over what the
  /// run actually dispatched, pluralized, and free of internal vocabulary.
  func testPartialDeliverySummaryCopy() {
    XCTAssertEqual(
      PartialDeliveryCopy.summary(
        DraftDeliveryFailure(
          failed_part_count: 5, dispatched_part_count: 9, reconciled_at: "2026-07-17T00:00:00Z"
        )
      ),
      "5 of 9 parts didn't send. Check Messages."
    )
    XCTAssertEqual(
      PartialDeliveryCopy.summary(
        DraftDeliveryFailure(
          failed_part_count: 1, dispatched_part_count: 3, reconciled_at: "2026-07-17T00:00:00Z"
        )
      ),
      "1 of 3 part didn't send. Check Messages."
    )
  }

  /// A corrupt record must never render "5 of 2".
  func testPartialDeliverySummaryClampsInconsistentCounts() {
    XCTAssertEqual(
      PartialDeliveryCopy.summary(
        DraftDeliveryFailure(
          failed_part_count: 5, dispatched_part_count: 2, reconciled_at: "2026-07-17T00:00:00Z"
        )
      ),
      "5 of 5 parts didn't send. Check Messages."
    )
  }
}
