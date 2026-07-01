import AppKit
import Foundation
import UserNotifications

@MainActor
final class MessageNotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

  private let settings: SettingsStore
  private let messagesViewState: MessagesViewState
  private let workPersonal: WorkPersonalStore
  private let onOpenConversation: (String) -> Void
  private var timer: Timer?
  private var lastSeenByConversation: [String: Date] = [:]
  private var isPolling = false

  init(
    settings: SettingsStore,
    messagesViewState: MessagesViewState,
    workPersonal: WorkPersonalStore,
    onOpenConversation: @escaping (String) -> Void
  ) {
    self.settings = settings
    self.messagesViewState = messagesViewState
    self.workPersonal = workPersonal
    self.onOpenConversation = onOpenConversation
    super.init()
  }

  func start() {
    UNUserNotificationCenter.current().delegate = self
    refreshAuthorizationStatus()
    establishBaseline()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.pollIfNeeded()
      }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.establishBaseline()
      }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.pollIfNeeded()
      }
    }
  }

  func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
      Task { @MainActor in self?.refreshAuthorizationStatus() }
    }
  }

  func openSystemNotificationSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }

  func refreshAuthorizationStatus() {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      Task { @MainActor in
        self?.authorizationStatus = settings.authorizationStatus
      }
    }
  }

  private func establishBaseline() {
    let conversations = loadDisplayedConversations(limit: 80)
    for conversation in conversations {
      if let date = conversation.recent.lastMessageDate {
        lastSeenByConversation[conversation.id] = max(lastSeenByConversation[conversation.id] ?? .distantPast, date)
      }
    }
    messagesViewState.preload(Array(conversations.prefix(ThreadPreloadPolicy.defaultLimit)))
  }

  private func pollIfNeeded() async {
    guard !isPolling,
          !NSApp.isActive,
          settings.newMessageNotificationsEnabled,
          authorizationStatus == .authorized || authorizationStatus == .provisional else {
      return
    }
    isPolling = true
    defer { isPolling = false }

    let conversations = loadDisplayedConversations(limit: 80)
    for conversation in conversations {
      guard let latestDate = conversation.recent.lastMessageDate else { continue }
      let baseline = lastSeenByConversation[conversation.id]
      guard baseline == nil || latestDate > baseline! else { continue }
      lastSeenByConversation[conversation.id] = latestDate

      guard MessageNotificationPolicy.visibleForWorkPersonal(
        enabled: workPersonal.enabled,
        filter: messagesViewState.workPersonalFilter,
        personLabel: workPersonal.personLabel(for: conversation.recent)
      ) else {
        continue
      }

      let loaded = (try? await RecentComposeThread.loadContextAsyncThrowing(for: conversation.recent.recipient, limit: 8)) ?? []
      let newInbound = loaded.filter {
        MessageNotificationPolicy.shouldNotify(
          appIsActive: NSApp.isActive,
          notificationsEnabled: settings.newMessageNotificationsEnabled,
          message: $0,
          baselineDate: baseline
        )
      }
      guard !newInbound.isEmpty else { continue }
      messagesViewState.storeMessages(
        loaded,
        for: conversation,
        loadedAllAvailableHistory: loaded.count < 8
      )
      deliverNotification(for: conversation, messages: newInbound)
    }
  }

  private func loadDisplayedConversations(limit: Int) -> [MessageConversation] {
    let loaded = MessageConversation.load(
      lookback: messagesViewState.lookback,
      drafts: [],
      includeWhatsApp: settings.whatsappEnabled
    )
    return Array(loaded.filter { conversation in
      MessageNotificationPolicy.visibleForWorkPersonal(
        enabled: workPersonal.enabled,
        filter: messagesViewState.workPersonalFilter,
        personLabel: workPersonal.personLabel(for: conversation.recent)
      )
    }.prefix(limit))
  }

  private func deliverNotification(for conversation: MessageConversation, messages: [ContextMessage]) {
    let content = UNMutableNotificationContent()
    let preview = MessageNotificationPolicy.preview(
      style: settings.newMessageNotificationPreviewStyle,
      conversationTitle: conversation.title,
      platform: conversation.platform,
      messages: messages
    )
    content.title = preview.title
    content.body = preview.body
    content.sound = .default
    content.userInfo = ["conversation_id": conversation.id]
    let request = UNNotificationRequest(
      identifier: "message-\(conversation.id)-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let conversationID = response.notification.request.content.userInfo["conversation_id"] as? String else {
      return
    }
    await MainActor.run {
      onOpenConversation(conversationID)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }
}
